#!/usr/bin/env bash
# Diagnóstico e correção conservadora para logout inesperado no MATE.
# Compatível com Bash 3.x+. Execute: sudo bash corrigir-mate.sh
# Cria backup antes de alterar configurações e gera ~/volta.sh para rollback offline.

set -u
umask 077

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -ne 0 ]; then
    say "ERRO: execute com sudo: sudo bash $0"
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = root ]; then
    say "ERRO: não consegui identificar o usuário gráfico. Execute da sessão afetada usando sudo."
    exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    say "ERRO: diretório pessoal do usuário $TARGET_USER não encontrado."
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$TARGET_HOME/backup-mate-logout-$STAMP"
mkdir -p "$BACKUP_ROOT"/{etc,home,system,logs,inventory}
chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$BACKUP_ROOT" 2>/dev/null || true
chmod 700 "$BACKUP_ROOT"

say "==> Coletando inventário antes de qualquer alteração..."
{
    date
    uname -a
    cat /etc/os-release 2>/dev/null || true
    printf '\n--- sessão ---\n'
    loginctl list-sessions 2>/dev/null || true
    printf '\n--- desktop ---\n'
    printf 'XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-indisponível}"
    printf 'DESKTOP_SESSION=%s\n' "${DESKTOP_SESSION:-indisponível}"
    printf '\n--- memória/swap ---\n'
    free -h 2>/dev/null || free -m 2>/dev/null || true
    cat /proc/meminfo 2>/dev/null || true
    swapon --show 2>/dev/null || true
    printf '\n--- armazenamento ---\n'
    df -hT 2>/dev/null || df -h 2>/dev/null || true
    df -ih 2>/dev/null || true
    printf '\n--- GPU/driver/módulos ---\n'
    lspci -nnk 2>/dev/null | grep -A5 -Ei 'VGA|3D|Display' || true
    lsmod 2>/dev/null || true
    printf '\n--- pacotes relevantes ---\n'
    dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
      'mate-*' 'marco*' 'lightdm*' 'xserver-xorg*' 'mesa-*' 'libgl1*' \
      'linux-modules*' 'systemd*' 'firefox*' 'chromium*' 2>/dev/null || true
    printf '\n--- serviços ---\n'
    systemctl --no-pager --full status display-manager 2>&1 || true
    systemctl --no-pager --full status systemd-oomd 2>&1 || true
    printf '\n--- compositor MATE ---\n'
    su - "$TARGET_USER" -c 'gsettings get org.mate.Marco.general compositing-manager' 2>&1 || true
} > "$BACKUP_ROOT/inventory/diagnostico.txt" 2>&1

# Backup amplo e anterior às alterações: configurações do sistema, sessão MATE,
# inventário de pacotes, módulos e logs disponíveis.
for p in /etc/X11 /etc/lightdm /etc/systemd /etc/modprobe.d /etc/default/grub /etc/fstab; do
    [ -e "$p" ] && cp -a --parents "$p" "$BACKUP_ROOT/etc/" 2>/dev/null || true
done
for p in "$TARGET_HOME/.config/dconf" "$TARGET_HOME/.config/mate" \
         "$TARGET_HOME/.config/mate-session" "$TARGET_HOME/.config/monitors.xml" \
         "$TARGET_HOME/.local/share" "$TARGET_HOME/.xsessionrc" \
         "$TARGET_HOME/.profile" "$TARGET_HOME/.bashrc"; do
    [ -e "$p" ] && cp -a --parents "$p" "$BACKUP_ROOT/home/" 2>/dev/null || true
done
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
    > "$BACKUP_ROOT/inventory/pacotes-dpkg.tsv" 2>&1 || true
apt-mark showmanual > "$BACKUP_ROOT/inventory/pacotes-manuais.txt" 2>&1 || true
lsmod > "$BACKUP_ROOT/inventory/lsmod.txt" 2>&1 || true
lspci -nnk > "$BACKUP_ROOT/inventory/lspci-nnk.txt" 2>&1 || true
cp -a /var/lib/dpkg/status "$BACKUP_ROOT/system/dpkg-status" 2>/dev/null || true
cp -a /etc/apt/sources.list /etc/apt/sources.list.d "$BACKUP_ROOT/etc/" 2>/dev/null || true
journalctl -b --no-pager > "$BACKUP_ROOT/logs/journal-atual.txt" 2>&1 || true
journalctl -b -1 --no-pager > "$BACKUP_ROOT/logs/journal-anterior.txt" 2>&1 || true
journalctl -k -b --no-pager > "$BACKUP_ROOT/logs/kernel-atual.txt" 2>&1 || true
journalctl -k -b -1 --no-pager > "$BACKUP_ROOT/logs/kernel-anterior.txt" 2>&1 || true
for f in /var/log/Xorg.0.log /var/log/Xorg.0.log.old /var/log/syslog /var/log/kern.log /var/log/auth.log; do
    [ -r "$f" ] && cp -a "$f" "$BACKUP_ROOT/logs/" 2>/dev/null || true
done

# Cria rollback local que não depende de internet. Restaura cópias de configuração
# e o valor anterior do compositor; não reinstala pacotes nem modifica kernel.
ROLLBACK="$TARGET_HOME/volta.sh"
cat > "$ROLLBACK" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
set -u
if [ "$(id -u)" -ne 0 ]; then
    echo "Execute: sudo bash ~/volta.sh"
    exit 1
fi
TARGET_USER="${SUDO_USER:-}"
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] || TARGET_USER="$(logname 2>/dev/null || true)"
[ -n "$TARGET_USER" ] || { echo "Não foi possível identificar o usuário."; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
[ -n "$TARGET_HOME" ] || { echo "HOME não encontrado."; exit 1; }
BACKUP_ROOT="$(find "$TARGET_HOME" -maxdepth 1 -type d -name 'backup-mate-logout-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
[ -n "$BACKUP_ROOT" ] && [ -d "$BACKUP_ROOT" ] || { echo "Backup não encontrado em $TARGET_HOME."; exit 1; }
echo "Backup usado: $BACKUP_ROOT"
echo "Restaurando configurações salvas (arquivos existentes poderão ser substituídos)."
if [ -d "$BACKUP_ROOT/etc/etc" ]; then
    cp -a "$BACKUP_ROOT/etc/etc/." /etc/
fi
if [ -d "$BACKUP_ROOT/home/home/$TARGET_USER" ]; then
    cp -a "$BACKUP_ROOT/home/home/$TARGET_USER/." "$TARGET_HOME/"
fi
if [ -f "$BACKUP_ROOT/inventory/compositor-anterior.txt" ]; then
    OLD="$(cat "$BACKUP_ROOT/inventory/compositor-anterior.txt")"
    if [ "$OLD" = true ] || [ "$OLD" = false ]; then
        su - "$TARGET_USER" -c "gsettings set org.mate.Marco.general compositing-manager $OLD" 2>/dev/null || true
    fi
fi
chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$TARGET_HOME/.config" 2>/dev/null || true
echo "Restauração concluída. Reinicie a sessão gráfica manualmente quando for seguro."
ROLLBACK_EOF
chmod 700 "$ROLLBACK"
chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$ROLLBACK"

# Registra o valor anterior antes de mudar qualquer configuração.
OLD_COMPOSITOR="$(su - "$TARGET_USER" -c 'gsettings get org.mate.Marco.general compositing-manager' 2>/dev/null | tr -d "'" || true)"
printf '%s\n' "$OLD_COMPOSITOR" > "$BACKUP_ROOT/inventory/compositor-anterior.txt"
chown "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$BACKUP_ROOT/inventory/compositor-anterior.txt"

# Varredura de utilitários e versões. Instala somente ferramentas de diagnóstico
# ausentes, via APT, sem upgrade geral. Se não houver rede, prossegue sem instalar.
MISSING=""
for cmd in free swapon lspci lsmod journalctl gsettings; do
    if ! have "$cmd"; then MISSING="$MISSING $cmd"; fi
done
{
    echo "Ferramentas ausentes antes da correção:$MISSING"
    for cmd in bash dpkg-query apt-get free swapon lspci lsmod journalctl gsettings; do
        if have "$cmd"; then printf '%s: ' "$cmd"; "$cmd" --version 2>&1 | head -1; else echo "$cmd: ausente"; fi
    done
} > "$BACKUP_ROOT/inventory/ferramentas.txt"

if have apt-get && have dpkg-query; then
    PKGS=""
    have lspci || PKGS="$PKGS pciutils"
    have free || PKGS="$PKGS procps"
    if [ -n "$PKGS" ]; then
        echo "Tentando instalar somente ferramentas de diagnóstico ausentes:$PKGS"
        DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=0 -o Acquire::http::Timeout=8 >/dev/null 2>&1 &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PKGS >/dev/null 2>&1 ||
        echo "AVISO: instalação de ferramentas não concluída (possível falta de rede)."
    fi
fi

# Coleta sinais de OOM/crash e drivers depois da varredura.
{
    echo "--- erros e OOM do boot atual/anterior ---"
    journalctl -b --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process|segfault|core dumped|lightdm|mate-session|marco|Xorg|GPU|i915|amdgpu|nouveau|nvidia' | tail -250 || true
    journalctl -b -1 --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process|segfault|core dumped|lightdm|mate-session|marco|Xorg|GPU|i915|amdgpu|nouveau|nvidia' | tail -250 || true
} > "$BACKUP_ROOT/logs/indicadores-crash.txt" 2>&1

# Correção reversível de baixo risco: desativar composição do Marco (MATE),
# frequentemente relacionada a falhas de renderização em hardware antigo.
# Não altera driver, kernel, display manager, swap ou pacotes gráficos.
if su - "$TARGET_USER" -c 'gsettings list-schemas' 2>/dev/null | grep -qx 'org.mate.Marco.general'; then
    if su - "$TARGET_USER" -c 'gsettings list-keys org.mate.Marco.general' 2>/dev/null | grep -qx 'compositing-manager'; then
        if su - "$TARGET_USER" -c 'gsettings set org.mate.Marco.general compositing-manager false' 2>/dev/null; then
            say "Correção aplicada: composição gráfica do Marco desativada (reversível)."
        else
            say "AVISO: não foi possível alterar o compositor na sessão atual."
        fi
    else
        say "AVISO: chave de composição não encontrada; nenhuma alteração gráfica aplicada."
    fi
else
    say "AVISO: esquema do MATE não encontrado; nenhuma alteração gráfica aplicada."
fi

# Diagnóstico final e resumo.
{
    date
    echo "Backup: $BACKUP_ROOT"
    echo "Rollback: $ROLLBACK"
    echo "Compositor anterior: ${OLD_COMPOSITOR:-indisponível}"
    echo "Compositor atual:"
    su - "$TARGET_USER" -c 'gsettings get org.mate.Marco.general compositing-manager' 2>&1 || true
    echo "Memória/swap:"
    free -h 2>&1 || true
    swapon --show 2>&1 || true
    echo "Espaço em disco:"
    df -h "$TARGET_HOME" / 2>&1 || true
    echo "Indicadores de falha: $BACKUP_ROOT/logs/indicadores-crash.txt"
} | tee "$BACKUP_ROOT/RESUMO.txt"

say ""
say "Concluído. Backup: $BACKUP_ROOT"
say "Rollback offline: sudo bash \"$ROLLBACK\""
say "Não reiniciei o sistema nem alterei kernel, driver ou gerenciador de login."
say "Se o logout persistir, envie o arquivo logs/indicadores-crash.txt e inventory/diagnostico.txt."
