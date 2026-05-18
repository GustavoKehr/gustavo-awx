# SQL Server Log Shipping em WSFC — Guia de Implementação

Configuração de Log Shipping entre uma instância FCI (WOORIDBCL) e um servidor DR standalone (sqlvm01), com o share de log shipping como recurso de cluster para sobreviver ao failover automaticamente.

Parte do conjunto: [`sqlserver_guide.md`](sqlserver_guide.md) · [`sqlserver_ha_guide.md`](sqlserver_ha_guide.md) · [`sqlserver_runbook.md`](sqlserver_runbook.md)

---

## Arquitetura

```
Site Principal (WSFC)                               Site DR
┌─────────────────────────────────────────────┐    ┌─────────────────────────────────────┐
│  Role: SQL Server (MSSQLSERVER)             │    │  sqlvm01  —  standalone             │
│  ├── Cluster Disk 1 (B:\)                   │    │  ├── G:\MSSQL16.MSSQLVAI\MSSQL\DATA\│
│  ├── SQL Server (VNN: WOORIDBCL)            │───►│  ├── G:\MSSQL16.MSSQLVAI\MSSQL\LOG\ │
│  ├── SQL Server Agent (ALWAYSON\sqlsrvr)    │    │  └── G:\LogShipping\jorge (clara)   │
│  └── LS_Backup_Share                        │    │                                     │
│      \\WOORIDBCL\logshipping                │    │  Jobs:                              │
│      ├── jorge\backup\  (*.trn)             │    │  LSCopy_WOORIDBCL_jorge             │
│      └── clara\backup\  (*.trn)             │    │  LSRestore_WOORIDBCL_jorge          │
│                                             │    │  LSCopy_WOORIDBCL_clara             │
│  wbdb-001 ◄────── failover ──────► wbdb-002 │    │  LSRestore_WOORIDBCL_clara          │
└─────────────────────────────────────────────┘    └─────────────────────────────────────┘
```

O share `\\WOORIDBCL\logshipping` é recurso do mesmo role do SQL Server. No failover, B:\, SQL Server e share migram juntos para wbdb-002 — o sqlvm01 continua copiando .trn sem intervenção manual.

---

## Inventário do Ambiente

| Componente | Valor | Observação |
|---|---|---|
| VNN Primary | `WOORIDBCL` | Sempre conectar por aqui |
| IP Virtual SQL | `192.168.137.66` | |
| Nó 1 (ativo) | `wbdb-001` | Owner node atual |
| Nó 2 (passivo) | `wbdb-002` | |
| Servidor DR | `sqlvm01` | Standalone, outra subnet |
| Conta SQL Agent Primary | `ALWAYSON\sqlsrvr` | Permissão no share |
| Conta SQL Agent DR | `NT Service\SQLAgent$MSSQLVAI` | Permissão nas pastas G:\ |
| Disco cluster | `B:\` | Shared disk do WSFC |
| Share Log Shipping | `\\WOORIDBCL\logshipping` | Recurso do role SQL Server |
| Bancos | `jorge`, `clara` | Mesma instância WOORIDBCL |
| Path dados DR | `G:\MSSQL16.MSSQLVAI\MSSQL\DATA\` | |
| Path logs DR | `G:\MSSQL16.MSSQLVAI\MSSQL\LOG\` | |
| Path .trn DR | `G:\LogShipping\jorge` / `clara` | Pasta local temporária |

---

## Fases de Implementação

| Fase | Onde | O que faz |
|---|---|---|
| 1 | wbdb-001 (PowerShell) | Criar share `LS_Backup_Share` como recurso de cluster |
| 2 | WOORIDBCL (T-SQL) | Verificar recovery model FULL e msdb em disco compartilhado |
| 3 | wbdb-001 / sqlvm01 (PowerShell) | Criar estrutura de pastas e permissões |
| 4 | WOORIDBCL (T-SQL/SSMS) | Backup FULL + LOG inicial dos bancos |
| 5 | sqlvm01 (T-SQL/SSMS) | Restore em NORECOVERY dos bancos |
| 6 | WOORIDBCL (SSMS Wizard) | Configurar Log Shipping Primary + Secondary |
| 7 | WOORIDBCL + sqlvm01 (SSMS) | Habilitar e testar jobs LSBackup, LSCopy, LSRestore |
| 8 | WOORIDBCL (T-SQL/SSMS) | Criar jobs Backup FULL semanal e DIFF diário |

---

## Fase 1 — Share como Recurso de Cluster

> **NUNCA** use `New-SmbShare` para o share do Log Shipping. Shares criados fora do cluster não fazem failover — o sqlvm01 perde acesso aos .trn quando o cluster migra para wbdb-002.

Execute no PowerShell do **wbdb-001** (nó ativo):

```powershell
Add-ClusterResource `
  -Name 'LS_Backup_Share' `
  -ResourceType 'File Share' `
  -Group 'SQL Server (MSSQLSERVER)'

Get-ClusterResource 'LS_Backup_Share' | `
  Set-ClusterParameter -Multiple @{
    ShareName = 'logshipping'
    Path      = 'B:\LogShipping'
    Remark    = 'Log Shipping UNC Share'
  }

Start-ClusterResource 'LS_Backup_Share'
```

Verificar acesso do sqlvm01 ao share (execute no **sqlvm01**):

```cmd
dir \\WOORIDBCL\logshipping
```

---

## Fase 2 — Pré-Requisitos (WOORIDBCL)

```sql
-- Recovery Model: deve ser FULL
SELECT name, recovery_model_desc
FROM sys.databases
WHERE name IN ('jorge', 'clara');

-- Corrigir se necessário
ALTER DATABASE jorge SET RECOVERY FULL;
ALTER DATABASE clara SET RECOVERY FULL;

-- msdb deve estar em disco de cluster (B:\), NUNCA C:\
-- Garante que os jobs façam failover automaticamente
SELECT name, physical_name
FROM sys.master_files
WHERE database_id = DB_ID('msdb');
```

---

## Fase 3 — Estrutura de Pastas e Permissões

**No cluster** (wbdb-001 com B:\ online):

```powershell
New-Item -ItemType Directory -Force -Path B:\LogShipping\jorge\backup
New-Item -ItemType Directory -Force -Path B:\LogShipping\clara\backup
New-Item -ItemType Directory -Force -Path B:\FULL
New-Item -ItemType Directory -Force -Path B:\DIFF
```

**No sqlvm01:**

```powershell
New-Item -ItemType Directory -Force -Path G:\LogShipping\jorge
New-Item -ItemType Directory -Force -Path G:\LogShipping\clara
```

**Permissão da conta de serviço** (PowerShell no wbdb-001):

```powershell
$acl  = Get-Acl 'B:\LogShipping'
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'ALWAYSON\sqlsrvr', 'FullControl',
    'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl 'B:\LogShipping' $acl
```

---

## Fase 4 — Backup Inicial (WOORIDBCL)

> Deve ser feito **antes** de abrir o wizard do SSMS — o wizard assume que o banco já existe em NORECOVERY no sqlvm01.

```sql
-- FULL inicial
BACKUP DATABASE jorge
TO DISK = 'B:\LogShipping\jorge\backup\jorge_INIT.bak'
WITH FORMAT, INIT, COMPRESSION,
     NAME = 'jorge - Backup Inicial Log Shipping';

-- LOG inicial — inicia a chain de LSN
BACKUP LOG jorge
TO DISK = 'B:\LogShipping\jorge\backup\jorge_LOG_INIT.trn'
WITH FORMAT, INIT, COMPRESSION,
     NAME = 'jorge - Log Backup Inicial';
```

Repetir para `clara` com os paths equivalentes em `clara\backup\`.

---

## Fase 5 — Restore no sqlvm01 (NORECOVERY)

Execute no **sqlvm01**:

```sql
-- Verificar nomes lógicos antes do restore
RESTORE FILELISTONLY
FROM DISK = '\\WOORIDBCL\logshipping\jorge\backup\jorge_INIT.bak';
-- Anotar coluna LogicalName — usar EXATAMENTE nos parâmetros MOVE

-- Restore FULL em NORECOVERY
RESTORE DATABASE jorge
FROM DISK = '\\WOORIDBCL\logshipping\jorge\backup\jorge_INIT.bak'
WITH NORECOVERY,
     MOVE 'jorge'     TO 'G:\MSSQL16.MSSQLVAI\MSSQL\DATA\jorge.mdf',
     MOVE 'jorge_log' TO 'G:\MSSQL16.MSSQLVAI\MSSQL\LOG\jorge_log.ldf',
     REPLACE;

-- Restore LOG inicial em NORECOVERY
RESTORE LOG jorge
FROM DISK = '\\WOORIDBCL\logshipping\jorge\backup\jorge_LOG_INIT.trn'
WITH NORECOVERY;
-- Banco deve ficar em estado: Restoring...
```

Repetir para `clara` com os paths equivalentes.

---

## Fase 6 — Configuração via SSMS Wizard (WOORIDBCL)

Conecte-se em **WOORIDBCL** no SSMS.

```
Object Explorer → Databases → botão direito em 'jorge'
  → Properties → Transaction Log Shipping
```

### 6.1 Habilitar Primary

Marque: **"Enable this as a primary database in a log shipping configuration"** → **Backup Settings...**

| Campo | Valor |
|---|---|
| Network path to backup folder | `\\WOORIDBCL\logshipping\jorge\backup` |
| If backup folder is on primary server, type local path | `B:\LogShipping\jorge\backup` |
| Delete files older than | 72 horas |
| Alert if no backup occurs within | 60 minutos |
| Backup job — Schedule | Every 15 minutes |

### 6.2 Adicionar Secondary → Add...

**Aba Initialize Secondary Database:**

| Campo | Valor |
|---|---|
| Secondary server instance | `sqlvm01` |
| Initialize secondary database | **No, the secondary database is initialized** ← restore já feito na Fase 5 |

**Aba Copy Files:**

| Campo | Valor |
|---|---|
| Destination folder for copied files | `G:\LogShipping\jorge` |
| Delete copied files after | 72 horas |
| Copy job — Schedule | Every 15 minutes |

**Aba Restore Transaction Log:**

| Campo | Valor |
|---|---|
| Database state when restoring backups | **No recovery mode** |
| Delay restoring backups at least | 0 minutos |
| Alert if no restore occurs within | 45 minutos |
| Restore job — Schedule | Every 15 minutes |

Clicar **OK → OK** para aplicar. Repetir para `clara`.

---

## Fase 7 — Habilitar e Testar Jobs

O wizard cria os jobs desabilitados. Habilitar via SSMS ou T-SQL:

```sql
-- WOORIDBCL
USE msdb;
EXEC sp_update_job @job_name = N'LSBackup_jorge', @enabled = 1;
EXEC sp_update_job @job_name = N'LSBackup_clara', @enabled = 1;

-- sqlvm01
USE msdb;
EXEC sp_update_job @job_name = N'LSCopy_WOORIDBCL_jorge',    @enabled = 1;
EXEC sp_update_job @job_name = N'LSRestore_WOORIDBCL_jorge', @enabled = 1;
EXEC sp_update_job @job_name = N'LSCopy_WOORIDBCL_clara',    @enabled = 1;
EXEC sp_update_job @job_name = N'LSRestore_WOORIDBCL_clara', @enabled = 1;
```

Teste manual via SSMS:

```
SSMS → SQL Server Agent → Jobs → [nome do job] → botão direito → Start Job at Step...
```

Ordem: LSBackup (WOORIDBCL) → LSCopy (sqlvm01) → LSRestore (sqlvm01).

---

## Fase 8 — Jobs Backup FULL e DIFF

> Não usar concatenação de strings ou `DECLARE` dentro do `@command` — causa erro de sintaxe no SQL Agent. Usar paths fixos.

### FULL semanal — domingo 22h (WOORIDBCL)

```sql
USE msdb;
EXEC sp_add_job @job_name = N'Backup_FULL_Semanal';
EXEC sp_add_jobstep
  @job_name  = N'Backup_FULL_Semanal',
  @step_name = N'Full Backup jorge e clara',
  @subsystem = N'TSQL',
  @command   = N'
BACKUP DATABASE jorge TO DISK = N''B:\FULL\jorge_full.bak''
WITH FORMAT, COMPRESSION, NAME = ''jorge Full Backup'';
BACKUP DATABASE clara TO DISK = N''B:\FULL\clara_full.bak''
WITH FORMAT, COMPRESSION, NAME = ''clara Full Backup'';';
EXEC sp_add_schedule
  @schedule_name          = N'Semanal_Dom_22h',
  @freq_type              = 8,
  @freq_interval          = 1,      -- domingo
  @freq_recurrence_factor = 1,
  @active_start_time      = 220000;
EXEC sp_attach_schedule @job_name = N'Backup_FULL_Semanal', @schedule_name = N'Semanal_Dom_22h';
EXEC sp_add_jobserver   @job_name = N'Backup_FULL_Semanal';
```

### DIFF diário — seg–sáb 22h (WOORIDBCL)

```sql
USE msdb;
EXEC sp_add_job @job_name = N'Backup_DIFF_Diario';
EXEC sp_add_jobstep
  @job_name  = N'Backup_DIFF_Diario',
  @step_name = N'Diff Backup jorge e clara',
  @subsystem = N'TSQL',
  @command   = N'
BACKUP DATABASE jorge TO DISK = N''B:\DIFF\jorge_diff.bak''
WITH DIFFERENTIAL, COMPRESSION, NAME = ''jorge Diff Backup'';
BACKUP DATABASE clara TO DISK = N''B:\DIFF\clara_diff.bak''
WITH DIFFERENTIAL, COMPRESSION, NAME = ''clara Diff Backup'';';
EXEC sp_add_schedule
  @schedule_name          = N'Diario_SegSab_22h',
  @freq_type              = 8,
  @freq_interval          = 126,    -- seg=2+ter=4+qua=8+qui=16+sex=32+sab=64
  @freq_recurrence_factor = 1,
  @active_start_time      = 220000;
EXEC sp_attach_schedule @job_name = N'Backup_DIFF_Diario', @schedule_name = N'Diario_SegSab_22h';
EXEC sp_add_jobserver   @job_name = N'Backup_DIFF_Diario';
```

---

## Jobs — Resumo

| Job | Servidor | Frequência | Função |
|---|---|---|---|
| `LSBackup_jorge` | WOORIDBCL | 15 min | Backup do log de jorge → B:\ |
| `LSBackup_clara` | WOORIDBCL | 15 min | Backup do log de clara → B:\ |
| `LSCopy_WOORIDBCL_jorge` | sqlvm01 | 15 min | Copia .trn do share → G:\LogShipping\jorge |
| `LSCopy_WOORIDBCL_clara` | sqlvm01 | 15 min | Copia .trn do share → G:\LogShipping\clara |
| `LSRestore_WOORIDBCL_jorge` | sqlvm01 | 15 min | Aplica logs no banco jorge |
| `LSRestore_WOORIDBCL_clara` | sqlvm01 | 15 min | Aplica logs no banco clara |
| `Backup_FULL_Semanal` | WOORIDBCL | Dom 22h | Full backup → B:\FULL\ |
| `Backup_DIFF_Diario` | WOORIDBCL | Seg–Sáb 22h | Diff backup → B:\DIFF\ |

> Jobs `LSBackup`, `FULL` e `DIFF` ficam no msdb compartilhado do cluster — fazem failover automaticamente. Jobs `LSCopy` e `LSRestore` ficam no sqlvm01 — independentes do cluster.

---

## Comandos de Verificação

```sql
-- Status do Primary (WOORIDBCL)
SELECT primary_database, last_backup_file, last_backup_date
FROM msdb.dbo.log_shipping_primary_databases
WHERE primary_database IN ('jorge', 'clara');

-- Status do Secondary (sqlvm01)
SELECT sd.secondary_database, sd.last_restored_file, sd.last_restored_date,
       mp.last_copied_file, mp.last_copied_date
FROM msdb.dbo.log_shipping_secondary_databases sd
LEFT JOIN msdb.dbo.log_shipping_monitor_secondary mp
  ON mp.secondary_database = sd.secondary_database
WHERE sd.secondary_database IN ('jorge', 'clara');

-- Histórico de execução dos jobs LSBackup
SELECT TOP 20 j.name,
  CASE h.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' END AS status,
  msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
  h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name LIKE 'LSBackup%'
ORDER BY h.run_date DESC, h.run_time DESC;
```

```
-- Monitoramento visual (SSMS):
SSMS → WOORIDBCL → botão direito na instância
  → Reports → Standard Reports → Transaction Log Shipping Status
```

```powershell
# Share online no cluster:
Get-ClusterResource 'LS_Backup_Share' | Select Name, State, OwnerNode

# Todos os recursos do role:
Get-ClusterResource | Where-Object OwnerGroup -eq 'SQL Server (MSSQLSERVER)' |
  Select Name, ResourceType, State, OwnerNode
```

---

## Consultar Dados no DR sem Quebrar o Log Shipping

```sql
-- 1. Colocar banco em STANDBY temporariamente (sqlvm01)
RESTORE DATABASE jorge
WITH STANDBY = 'G:\LogShipping\jorge\jorge_standby.bak';

-- 2. Consultar
SELECT * FROM jorge.dbo.Clientes;

-- 3. OBRIGATÓRIO: voltar para NORECOVERY antes do próximo ciclo
RESTORE DATABASE jorge WITH NORECOVERY;
```

> Esquecer o passo 3 = próximo .trn não pode ser aplicado = Log Shipping para.

---

## Reiniciar após Quebra de Cadeia de LSN

Ocorre quando: backup de log manual fora do job LSBackup, restore incorreto, ou qualquer operação que crie um .trn fora da nomenclatura `banco_YYYYMMDDHHMMSS.trn`.

```sql
-- 1. Novo FULL + LOG no WOORIDBCL
BACKUP DATABASE jorge TO DISK = 'B:\LogShipping\jorge\backup\jorge_REINIT.bak'
WITH FORMAT, INIT, COMPRESSION;
BACKUP LOG jorge TO DISK = 'B:\LogShipping\jorge\backup\jorge_LOG_REINIT.trn'
WITH FORMAT, INIT, COMPRESSION;

-- 2. Restore do zero no sqlvm01
RESTORE DATABASE jorge
FROM DISK = '\\WOORIDBCL\logshipping\jorge\backup\jorge_REINIT.bak'
WITH NORECOVERY,
     MOVE 'jorge'     TO 'G:\MSSQL16.MSSQLVAI\MSSQL\DATA\jorge.mdf',
     MOVE 'jorge_log' TO 'G:\MSSQL16.MSSQLVAI\MSSQL\LOG\jorge_log.ldf',
     REPLACE;
RESTORE LOG jorge
FROM DISK = '\\WOORIDBCL\logshipping\jorge\backup\jorge_LOG_REINIT.trn'
WITH NORECOVERY;

-- 3. Resetar controle do Log Shipping (sqlvm01)
UPDATE msdb.dbo.log_shipping_secondary_databases
SET last_restored_file = NULL, last_restored_date = NULL
WHERE secondary_database = 'jorge';

-- 4. Forçar Copy + Restore (sqlvm01)
EXEC sp_start_job N'LSCopy_WOORIDBCL_jorge';
WAITFOR DELAY '00:00:15';
EXEC sp_start_job N'LSRestore_WOORIDBCL_jorge';
```

---

## Comportamento no Failover do Cluster

```
Evento: wbdb-001 perde conectividade

1. WSFC detecta falha — inicia failover do grupo SQL Server
2. Cluster Disk 1 (B:\) desmonta em wbdb-001
3. Cluster Disk 1 (B:\) monta em wbdb-002
4. LS_Backup_Share (\\WOORIDBCL\logshipping) volta online em wbdb-002
5. SQL Server sobe em wbdb-002 com mesmo IP/VNN WOORIDBCL
6. SQL Agent sobe com os jobs do msdb compartilhado (B:\)
7. LSBackup_jorge e LSBackup_clara disparam normalmente em wbdb-002
8. sqlvm01 continua acessando \\WOORIDBCL\logshipping e copiando .trn

Resultado: Log Shipping continua sem nenhuma intervenção manual
```

| Recurso | wbdb-001 ativo | wbdb-002 ativo |
|---|---|---|
| `WOORIDBCL` (VNN) | wbdb-001 | wbdb-002 |
| Cluster Disk B:\ | wbdb-001 | wbdb-002 |
| `\\WOORIDBCL\logshipping` | Acessível | Acessível |
| `LSBackup_jorge` / `clara` | Rodando em wbdb-001 | Rodando em wbdb-002 |
| sqlvm01 copia .trn | Funciona | Funciona |

---

## Erros Comuns e Resolução

| Erro | Causa | Resolução |
|---|---|---|
| sqlvm01 perde acesso ao share após failover | Share criado fora do cluster (`New-SmbShare`) | Recriar o share como recurso de cluster (Fase 1) |
| `LSBackup` roda mas nenhum .trn gerado | Job desabilitado ou sem schedule | `sp_update_job @enabled=1`; verificar schedule no SSMS |
| `LSRestore` falha com "LSN out of sequence" | Backup de log manual fora do job quebrou a chain | Seguir procedimento Reiniciar após Quebra de LSN |
| Banco DR não aparece como "Restoring..." | Restore foi feito com RECOVERY em vez de NORECOVERY | Refazer Fase 5 com `WITH NORECOVERY` |
| `LSCopy` falha com "Access denied" ao share | Permissão de `NT Service\SQLAgent$MSSQLVAI` ausente no share | Adicionar permissão FullControl no B:\LogShipping para a conta |
| `BACKUP DATABASE clara TO DISK='jorge_diff.bak'` | Copy-paste errado no script | Verificar que o primeiro BACKUP no job DIFF usa `DATABASE jorge` |
| Restore falha: "Logical file not found" | Nome lógico no `MOVE` não confere com o do backup | Rodar `RESTORE FILELISTONLY` e corrigir os nomes nos parâmetros MOVE |
| msdb em C:\ — jobs somem após failover | msdb não está em disco de cluster | Mover msdb para B:\ antes de configurar Log Shipping |
| `sp_add_jobstep` falha com erro de sintaxe | Uso de `DECLARE` ou concatenação dentro do `@command` | Usar paths fixos no @command (sem variáveis T-SQL) |

---

## Checklist de Validação

| # | Verificação | Onde | Resultado Esperado |
|---|---|---|---|
| 1 | Recovery Model = FULL | WOORIDBCL | FULL para jorge e clara |
| 2 | msdb em disco compartilhado | WOORIDBCL | Path em B:\ (não C:\) |
| 3 | Share acessível do DR | sqlvm01 | `dir \\WOORIDBCL\logshipping` lista pastas |
| 4 | `LS_Backup_Share` Online | Failover Cluster Manager | Status Online no role |
| 5 | `LSBackup` habilitado + schedule | WOORIDBCL → SQL Agent | Enabled=1, schedule 15min |
| 6 | `LSCopy` e `LSRestore` habilitados | sqlvm01 → SQL Agent | Enabled=1 para jorge e clara |
| 7 | Bancos em Restoring no DR | sqlvm01 → Databases | jorge e clara: Restoring... |
| 8 | `last_restored_date` preenchido | sqlvm01 (query de verificação) | Data recente |
| 9 | Jobs FULL e DIFF com schedule | WOORIDBCL → SQL Agent | Semanal e diário configurados |
