# Guia SQL Server — Ansible & AWX

Referência técnica para os playbooks e roles SQL Server deste repositório.
Parte do conjunto: `general_guide.md` · `mysql_guide.md` · `postgres_guide.md` · `sqlserver_guide.md` · `oracle_guide.md`

---

## Playbook — install_sql_playbook.yml

```
Phase 1: storage_setup      → inicializar disco, formatar NTFS 64K, ACLs
Phase 2: security_hardening → IPsec policy via netsh (whitelist IPs para 1433/3389)
Phase 3: sql_pre_reqs       → desabilitar firewall, download ISO/SSMS, montar ISO
Phase 4: sql_install        → instalação silenciosa + SSMS
Phase 5: sql_post_config    → criar banco via sqlcmd, limpeza
Phase 6: sql_manage_users   → criar logins SQL ou Windows, mapear para banco
Phase 7: db_patches         → descoberta de patches (não aplica automaticamente)
```

---

## Módulos Windows (ansible.windows / community.windows)

| Módulo | Uso |
|---|---|
| `win_get_url` | Download do ISO SQL Server (~5 GB) e SSMS do repositoryvm |
| `win_disk_image` | Montar/desmontar ISO após download (`state: present/absent`) |
| `win_partition` | Criar partição no disco de dados (drive E:) |
| `win_format` | Formatar NTFS com `allocation_unit_size: 65536` (64 KB) |
| `win_acl` | Conceder Full Control para Network Service (SID `S-1-5-20`) |
| `win_package` | Instalar SQL Server (`setup.exe /Quiet /ConfigurationFile=...`) |
| `win_shell` | Executar PowerShell: gerenciar disco, `sqlcmd.exe` para DDL |
| `win_firewall` | Desabilitar Windows Firewall antes da instalação |

### Exemplos de uso

```yaml
# Formatar com NTFS 64 KB (otimizado para SQL Server — coincide com extent de 64 KB)
- community.windows.win_format:
    drive_letter: E
    file_system: ntfs
    new_label: SQL_DATA
    allocation_unit_size: 65536

# ACL para Network Service usando SID (independente do idioma do Windows)
- ansible.windows.win_acl:
    path: E:\SQLServer_Root
    user: S-1-5-20     # SID do Network Service — PT-BR seria "Serviço de Rede"
    rights: FullControl
    type: allow
    inherit: ContainerInherit,ObjectInherit

# Instalação silenciosa
- ansible.windows.win_package:
    path: "{{ disk_iso_mount.mount_paths[0] }}setup.exe"
    arguments: >-
      /ConfigurationFile=C:\ansible_temp\ConfigurationFile.ini
      /SAPWD="{{ sql_sa_password }}"
      /IAcceptSQLServerLicenseTerms
      /Quiet
    state: present

# Criar login SQL via sqlcmd
- ansible.windows.win_shell: |
    $sqlcmd = (Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Recurse -Filter "sqlcmd.exe").FullName | Select-Object -First 1
    & $sqlcmd -S localhost -Q "
      IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '{{ sql_login_name }}')
      BEGIN
        CREATE LOGIN [{{ sql_login_name }}] WITH PASSWORD = '{{ sql_login_password }}',
        CHECK_POLICY = ON, DEFAULT_DATABASE = [{{ sql_login_default_db }}]
      END"
  no_log: true
```

---

## Variáveis do survey AWX — sql_manage_users

| Variável | Valores | Observação |
|---|---|---|
| `sql_login_name` | string | Nome do login |
| `sql_login_type` | `sql` / `windows` | `sql` = senha; `windows` = Active Directory |
| `sql_login_state` | `present` / `absent` | `absent` dropa o login |
| `sql_target_database` | string | Banco alvo |
| `sql_database_roles` | lista | Ex: `["db_owner", "db_datareader"]` |
| `sql_sa_password` | string | Senha do SA — via survey, nunca em defaults |

### Roles de banco de dados SQL Server

| Role | Permissão |
|---|---|
| `db_owner` | Controle total do banco |
| `db_datareader` | SELECT em todas as tabelas |
| `db_datawriter` | INSERT, UPDATE, DELETE em todas as tabelas |
| `db_ddladmin` | CREATE, ALTER, DROP de objetos |
| `db_securityadmin` | Gerenciar permissões |

---

## Observações de design

### Por que cluster NTFS de 64 KB?
SQL Server lê/escreve em páginas de 8 KB (8 páginas por extent = 64 KB). Quando o cluster NTFS coincide com o extent do SQL, cada operação de I/O é atendida em uma única operação de disco. Com cluster padrão de 4 KB, são 16 operações por extent.

### Por que usar SID `S-1-5-20` em vez de "Network Service"?
O nome muda por idioma do Windows ("Serviço de Rede" em PT-BR). O SID é sempre o mesmo — torna o playbook portável entre Windows em diferentes idiomas.

### Por que IPsec em vez do Windows Firewall?
O firewall Windows é desabilitado no Phase 3 (antes da instalação). IPsec opera em nível mais baixo — funciona mesmo com o Windows Firewall desabilitado.

### Por que baixar de `repositoryvm` (192.168.137.148)?
O ambiente de trabalho não tem internet. O `repositoryvm` funciona como mirror interno HTTP com todos os binários (ISOs, patches) necessários.
