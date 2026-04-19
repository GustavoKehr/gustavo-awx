# Guia Oracle — Ansible & AWX

Referência técnica para os playbooks e roles Oracle deste repositório.
Parte do conjunto: `general_guide.md` · `mysql_guide.md` · `postgres_guide.md` · `sqlserver_guide.md` · `oracle_guide.md`

---

## Playbook — deploy_oracle.yml (via 01_db_provisioning.yml com db_type=oracle)

```
Phase 1: oracle_prereqs    → RPM preinstall, hugepages, sysctl, workarounds RHEL 9
Phase 2: oracle_dirs       → estrutura de diretórios, templates bash_profile/sysctl
Phase 3: oracle_transfer   → rsync binários do AWX para oraclevm (~5 GB)
Phase 4: oracle_install_sw → unzip + runInstaller silencioso + root.sh
Phase 5: oracle_patches    → opatch apply em sequência (ordem importa!)
Phase 6: oracle_dbcreate   → criar banco, verificar OPEN, aplicar profile SQL
```

```bash
# Rodar fases individualmente:
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_prereqs
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_transfer
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_install_sw
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_patches
ansible-playbook playbooks/deploy_oracle.yml --tags oracle_dbcreate
```

---

## Módulos utilizados

### Phase 1 — Pré-requisitos

```yaml
# RPM preinstall configura limites do kernel, grupos oracle/dba, parâmetros de SO
- ansible.builtin.dnf:
    name: oracle-database-preinstall-19c
    state: present
    disable_gpg_check: true    # repositório interno sem GPG

# Workaround: Oracle 19c não suporta RHEL 9 oficialmente
- ansible.builtin.command:
    cmd: mv /etc/init.d /etc/initd.back
    creates: /etc/initd.back   # idempotente — pula se já renomeado

# HugePages — calculado via formula: ceil(SGA / hugepage_size) + 1
- ansible.builtin.template:
    src: sysctl_oracle.conf.j2
    dest: /etc/sysctl.d/97-oracle-hugepages.conf
- ansible.builtin.command:
    cmd: sysctl --system
    changed_when: false
```

### Phase 3 — Transferência de binários

```yaml
# rsync para binários Oracle (~5 GB) — muito mais eficiente que copy
- ansible.posix.synchronize:
    src: "{{ oracle_install_source }}/"
    dest: "{{ oracle_stage_dir }}/"
    checksum: true
    recursive: true
```

### Phase 4 — Instalação do software

```yaml
# Descompactar binários no ORACLE_HOME
- ansible.builtin.unarchive:
    src: "{{ oracle_stage_dir }}/LINUX.X64_193000_db_home.zip"
    dest: "{{ oracle_home }}"
    remote_src: true
    creates: "{{ oracle_home }}/bin/runInstaller"   # idempotente

# Instalação silenciosa — rc=6 = sucesso com avisos (aceito)
- ansible.builtin.shell: |
    export CV_ASSUME_DISTID=RHEL8
    {{ oracle_home }}/runInstaller -silent -ignorePrereq \
      -applyRU {{ oracle_stage_dir }}/{{ oracle_ru_patch_dir }} \
      -responseFile {{ oracle_home }}/install/response/db_install.rsp
  become_user: oracle
  register: install_result
  failed_when: install_result.rc not in [0, 6]

# root.sh deve rodar como root após o instalador
- ansible.builtin.shell: "{{ oracle_home }}/root.sh"
```

### Phase 5 — Patches

```yaml
# opatch faz perguntas interativas — echo injeta as respostas
- ansible.builtin.shell: |
    echo -e "y\ny" | {{ oracle_home }}/OPatch/opatch apply \
      {{ oracle_patch_dir }}/{{ item }} -silent
  become_user: oracle
  loop: "{{ oracle_patch_list }}"   # ordem importa: RU antes de RUs individuais

# Verificar patches aplicados
- ansible.builtin.shell: "{{ oracle_home }}/OPatch/opatch lsinventory"
  become_user: oracle
  changed_when: false
  register: opatch_output
```

### Phase 6 — Criação do banco

```yaml
# dbca silencioso com arquivo de resposta
- ansible.builtin.shell: |
    {{ oracle_home }}/bin/dbca -silent -createDatabase \
      -responseFile {{ oracle_home }}/assistants/dbca/response/oracle_dbca.rsp
  become_user: oracle

# Verificar banco OPEN via sqlplus
- ansible.builtin.shell: |
    echo "SELECT status FROM v\$instance;" | \
      {{ oracle_home }}/bin/sqlplus -S / as sysdba
  become_user: oracle
  register: db_status
  failed_when: "'OPEN' not in db_status.stdout"

# Registrar banco no /etc/oratab (para oraenv funcionar)
- ansible.builtin.lineinfile:
    path: /etc/oratab
    line: "{{ oracle_sid }}:{{ oracle_home }}:Y"
    create: true
```

---

## Variáveis críticas — oracle_install (`defaults/main.yml`)

| Variável | Padrão | Observação |
|---|---|---|
| `oracle_sid` | `TSTOR` | Identificador do banco — muda a estrutura de diretórios |
| `oracle_sga_target` | `2G` | SGA — cache principal (similar ao buffer pool) |
| `oracle_pga_target` | `512m` | PGA — memória por sessão (sort, hash joins) |
| `oracle_hugepages` | `0` | `0` = cálculo automático; valor fixo = override |
| `oracle_character_set` | `WE8MSWIN1252` | Western Windows — atenção em migrações |
| `oracle_sys_password` | `""` | **Obrigatório via survey AWX** — vazio causa falha intencional |
| `oracle_ru_patch_dir` | `p37641958` | Atualizar a cada trimestre com novo RU da Oracle |

---

## Observações de design

### Por que `CV_ASSUME_DISTID=RHEL8`?
Oracle 19c não foi certificado para RHEL 9. Essa variável de ambiente faz o instalador acreditar que está em RHEL 8, contornando a verificação de plataforma.

### Por que `rc not in [0, 6]`?
O `runInstaller` retorna `rc=6` quando conclui com avisos (warnings) — isso é normal e esperado em instalações silenciosas. Tratar `rc=6` como falha bloquearia toda a automação.

### Por que `echo -e "y\ny" | opatch apply`?
O `opatch` faz perguntas interativas em modo não-silencioso. Em automação não há terminal para responder. O pipe com `echo` injeta as respostas automaticamente.

### Por que rsync (`synchronize`) para os binários?
O instalador Oracle + patches somam ~5 GB. O módulo `copy` carrega o arquivo inteiro na memória do control node. O `synchronize` usa rsync: transfere em stream, suporta retomada de transferência interrompida, e só retransfer o que mudou.

### Por que `oradism` precisa de SUID e `oracle:dba`?
O `oradism` é o daemon que aloca HugePages para o Oracle. Precisa de SUID bit para escalar privilégios e proprietário `oracle:dba` para ser chamado pelo processo Oracle. Sem isso, o banco não consegue alocar memória grande.

### Por que `-applyRU` durante o `runInstaller`?
Aplicar o Release Update durante a instalação (em vez de depois) é mais seguro: o banco já nasce no patch level correto. Aplicar depois requer parar o banco, aplicar, reiniciar — mais passos e mais risco.
