# Requisitos para Ambiente Offline (Trabalho)

> Este projeto será replicado em VMs **sem acesso à internet**.
> Todos os artefatos abaixo precisam estar disponíveis localmente antes da execução.

## 1. Coleções Ansible

Declaradas em `collections/requirements.yml`. Instalar em máquina com internet e copiar para o AWX.

```bash
# Rodar em máquina COM internet
ansible-galaxy collection install -r collections/requirements.yml -p /opt/collections

# Copiar a árvore gerada para o AWX (SCP, USB, etc.)
# Estrutura esperada no AWX:
# /opt/collections/ansible_collections/community/mysql/
# /opt/collections/ansible_collections/community/postgresql/
# /opt/collections/ansible_collections/ansible/windows/
# /opt/collections/ansible_collections/community/windows/
```

No AWX, desabilitar "Install collections" no Projeto para não tentar acessar o Galaxy.

## 2. Pacotes de SO (Linux RHEL 9)

### MySQL
- `mysql-server`
- `python3-PyMySQL`

### PostgreSQL
- `postgresql-server`
- `postgresql`
- `python3-psycopg2`

### SQL Server
- `mssql-server` (repositório Microsoft)
- `mssql-tools`
- `unixODBC-devel`

**Opções para ambiente offline:**
- Configurar um repositório local (ex: `repositoryvm` 192.168.137.148) com `createrepo`
- Ou usar `dnf download --resolve` em máquina com internet e servir via HTTP

## 3. Execution Environment (EE) do AWX

AWX usa containers para executar os jobs. A imagem atual é `AWX EE (24.6.1)`.

Em ambiente offline a imagem precisa estar disponível localmente:
```bash
# Exportar a imagem (máquina com internet)
podman pull ghcr.io/ansible/awx-ee:24.6.1
podman save ghcr.io/ansible/awx-ee:24.6.1 -o awx-ee-24.6.1.tar

# Importar no host AWX (sem internet)
podman load -i awx-ee-24.6.1.tar
```

## 4. Checklist de replicação para o trabalho

- [ ] Exportar coleções Ansible para `/opt/collections`
- [ ] Configurar `repositoryvm` como mirror de pacotes RPM
- [ ] Exportar e importar imagem do AWX EE
- [ ] Ajustar `ansible.cfg` com caminhos locais
- [ ] Desabilitar "Update on Launch" e "Install collections" no Projeto AWX
- [ ] Ajustar inventário com os IPs corretos do ambiente de trabalho
- [ ] Validar conectividade SSH com `user_aap` em todos os hosts alvo
