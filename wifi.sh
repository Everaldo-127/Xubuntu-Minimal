#!/usr/bin/env bash
# WIFI-RECOVERY — Ubuntu 24.04 e derivados Debian/Ubuntu com APT
# Conexao Wi-Fi via CLI/TTY. Nao altera o ambiente grafico.

set -uo pipefail
umask 077

VERSION="2.3"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/wifi-cache"
DEB_DIR="$CACHE_DIR/debs"
LOG_DIR="/var/log/wifi-recovery"
BACKUP_ROOT="/var/backups/wifi-recovery"
STAMP="$(date +%Y%m%d-%H%M%S)"

REQUIRED_PACKAGES=(network-manager wpasupplicant)
OPTIONAL_PACKAGES=(rfkill)

if (( EUID != 0 )); then
    echo "Execute com: sudo bash \"$0\""
    exit 1
fi

mkdir -p "$CACHE_DIR" "$DEB_DIR" "$LOG_DIR" "$BACKUP_ROOT" || {
    echo "ERRO: nao foi possivel criar os diretorios de trabalho."
    exit 1
}
chmod 700 "$LOG_DIR" "$BACKUP_ROOT"

LOG_FILE="$LOG_DIR/recovery-$STAMP.log"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERRO: $*"
    echo "Consulte o log: $LOG_FILE"
    exit 1
}

[[ -r /etc/os-release ]] || die "Arquivo /etc/os-release nao encontrado."
# shellcheck disable=SC1091
source /etc/os-release

command -v apt-get >/dev/null 2>&1 || die "APT nao encontrado."
command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query nao encontrado."

if [[ "${ID:-}" != "ubuntu" &&
      " ${ID_LIKE:-} " != *" ubuntu "* &&
      " ${ID_LIKE:-} " != *" debian "* ]]; then
    die "Sistema nao reconhecido como Ubuntu ou derivado Debian/Ubuntu."
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || echo desconhecida)"
KERNEL="$(uname -r)"

printf '\n==================================================\n'
printf '             WIFI RECOVERY - %s\n' "$VERSION"
printf '==================================================\n'
printf 'Sistema:      %s\n' "${PRETTY_NAME:-desconhecido}"
printf 'Distribuicao: %s\n' "${ID:-desconhecida}"
printf 'Versao:       %s\n' "${VERSION_ID:-desconhecida}"
printf 'Arquitetura:  %s\n' "$ARCH"
printf 'Kernel:       %s\n' "$KERNEL"
printf '==================================================\n\n'

log "Sistema: ${PRETTY_NAME:-desconhecido}; kernel: $KERNEL; arquitetura: $ARCH"

package_installed() {
    local status
    status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
    [[ "$status" == "install ok installed" ]]
}

missing_packages() {
    local package
    for package in "$@"; do
        package_installed "$package" || printf '%s\n' "$package"
    done
}

has_internet() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --connect-timeout 3 --max-time 5 \
            https://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=5 \
            https://archive.ubuntu.com/ubuntu/
        return $?
    fi

    return 1
}

backup_environment() {
    log "Criando backup preventivo."
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR"

    local item
    for item in \
        /etc/NetworkManager \
        /etc/netplan \
        /etc/wpa_supplicant \
        /etc/network \
        /etc/systemd/network \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d
    do
        if [[ -e "$item" ]]; then
            cp -a --parents "$item" "$BACKUP_DIR/" \
                >>"$LOG_FILE" 2>&1 ||
                log "AVISO: nao foi possivel copiar $item."
        fi
    done

    dpkg-query -W -f='${binary:Package}\t${Version}\n' \
        >"$BACKUP_DIR/packages.txt" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active NetworkManager \
            >"$BACKUP_DIR/networkmanager-active.txt" 2>&1 || true
        systemctl is-enabled NetworkManager \
            >"$BACKUP_DIR/networkmanager-enabled.txt" 2>&1 || true
    fi

    log "Backup salvo em $BACKUP_DIR"
}

backup_environment || die "Nao foi possivel criar o backup."

install_missing_packages() {
    local -a missing=("$@")
    local deb
    local count=0

    ((${#missing[@]} > 0)) || return 0

    if ! has_internet; then
        log "Sem internet. Pacotes ausentes: ${missing[*]}"

        # Tenta usar os DEBs previamente guardados no cache local.
        if compgen -G "$DEB_DIR/*.deb" >/dev/null; then
            cp -n "$DEB_DIR"/*.deb /var/cache/apt/archives/ \
                2>/dev/null || true

            if apt-get --no-download --no-upgrade install -y \
                "${missing[@]}" >>"$LOG_FILE" 2>&1; then
                return 0
            fi
        fi

        return 1
    fi

    log "Baixando pacotes ausentes e dependencias: ${missing[*]}"

    if ! apt-get --download-only --no-upgrade install -y \
        "${missing[@]}" >>"$LOG_FILE" 2>&1; then
        log "Falha no download. Verifique repositorios e indices APT."
        return 1
    fi

    shopt -s nullglob
    for deb in /var/cache/apt/archives/*.deb; do
        if cp -n -- "$deb" "$DEB_DIR/" 2>/dev/null; then
            ((count += 1))
        fi
    done
    shopt -u nullglob

    log "Pacotes DEB copiados para o cache local: $count"

    if ! DEBIAN_FRONTEND=noninteractive \
        apt-get --no-upgrade install -y "${missing[@]}" \
        >>"$LOG_FILE" 2>&1; then
        log "Falha ao instalar pacotes ausentes."
        return 1
    fi

    local package
    for package in "${missing[@]}"; do
        package_installed "$package" || return 1
    done

    printf 'Sistema=%s\nVersao=%s\nArquitetura=%s\nKernel=%s\nData=%s\n' \
        "${ID:-unknown}" "${VERSION_ID:-unknown}" "$ARCH" "$KERNEL" \
        "$STAMP" >"$CACHE_DIR/manifest.txt"
}

ensure_packages() {
    local -a missing=() optional_missing=()

    mapfile -t missing < <(
        missing_packages "${REQUIRED_PACKAGES[@]}"
    )

    if ((${#missing[@]})); then
        install_missing_packages "${missing[@]}" ||
            die "Nao foi possivel instalar os pacotes obrigatorios."
    else
        log "Pacotes obrigatorios ja instalados; APT nao sera executado para eles."
    fi

    mapfile -t optional_missing < <(
        missing_packages "${OPTIONAL_PACKAGES[@]}"
    )

    if ((${#optional_missing[@]})); then
        if has_internet; then
            install_missing_packages "${optional_missing[@]}" ||
                log "AVISO: pacote opcional nao instalado: ${optional_missing[*]}"
        else
            log "Modo offline: pacotes opcionais ausentes ignorados."
        fi
    fi

    package_installed network-manager ||
        die "network-manager nao esta instalado."

    package_installed wpasupplicant ||
        die "wpasupplicant nao esta instalado."

    command -v nmcli >/dev/null 2>&1 ||
        die "Comando nmcli indisponivel."
}

start_networkmanager() {
    command -v systemctl >/dev/null 2>&1 ||
        die "systemctl indisponivel."

    systemctl cat NetworkManager.service >/dev/null 2>&1 ||
        die "Servico NetworkManager nao encontrado."

    if systemctl is-active --quiet NetworkManager; then
        log "NetworkManager ja esta ativo."
    else
        log "Iniciando NetworkManager (sem habilitar inicio permanente no boot)."
        systemctl start NetworkManager >>"$LOG_FILE" 2>&1 ||
            die "Nao foi possivel iniciar NetworkManager."
    fi

    local attempt
    for attempt in {1..15}; do
        nmcli general status >/dev/null 2>&1 && return 0
        sleep 1
    done

    die "NetworkManager nao respondeu."
}

enable_wifi() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >>"$LOG_FILE" 2>&1 || true
    fi

    nmcli radio wifi on >>"$LOG_FILE" 2>&1 || true
    sleep 2

    if ! nmcli -t -f DEVICE,TYPE device status | grep -q ':wifi$'; then
        nmcli device status || true
        command -v rfkill >/dev/null 2>&1 && rfkill list || true
        die "Nenhuma interface Wi-Fi disponivel. Verifique driver, firmware ou bloqueio fisico."
    fi
}

declare -a NETWORKS=()
SELECTED_SSID=""

scan_networks() {
    local output ssid
    NETWORKS=()

    nmcli device wifi rescan >>"$LOG_FILE" 2>&1 || true
    sleep 3

    output="$(nmcli -t --escape no -f SSID device wifi list \
        2>>"$LOG_FILE")" || return 1

    while IFS= read -r ssid; do
        [[ -n "$ssid" ]] || continue
        NETWORKS+=("$ssid")
    done <<<"$output"

    ((${#NETWORKS[@]} > 0)) || return 1

    printf '\n================ REDES WI-FI ================\n'

    local i
    for i in "${!NETWORKS[@]}"; do
        printf '%3d) %s\n' "$((i + 1))" "${NETWORKS[$i]}"
    done

    printf '=============================================\n'
}

select_network() {
    local choice

    while true; do
        if ! scan_networks; then
            echo "Nenhuma rede visivel encontrada."
            read -r -p "ENTER para tentar novamente ou Q para sair: " choice
            [[ "$choice" =~ ^[Qq]$ ]] && return 1
            continue
        fi

        read -r -p "Numero da rede (R para atualizar): " choice
        [[ "$choice" =~ ^[Rr]$ ]] && continue

        if [[ ! "$choice" =~ ^[0-9]+$ ]] ||
            ((choice < 1 || choice > ${#NETWORKS[@]})); then
            echo "Selecao invalida."
            continue
        fi

        SELECTED_SSID="${NETWORKS[$((choice - 1))]}"
        return 0
    done
}

connect_wifi() {
    local ssid="$1"
    local iface

    iface="$(nmcli -t -f DEVICE,TYPE device status |
        awk -F: '$2 == "wifi" {print $1; exit}')"

    [[ -n "$iface" ]] || die "Interface Wi-Fi indisponivel."

    echo
    echo "Rede selecionada: $ssid"
    echo "Se necessario, o NetworkManager solicitara a senha."
    echo "A senha nao sera escrita no log do script."
    echo

    nmcli --ask device wifi connect "$ssid" ifname "$iface" || return 1
    sleep 3

    printf '\n================ ESTADO DA REDE ================\n'
    nmcli device status

    printf '\n================ ENDERECOS IP ==================\n'
    ip -brief address show "$iface" || true

    printf '\n================ ROTA PADRAO ===================\n'
    ip route show default
    printf '\n'

    if ip -4 address show dev "$iface" | grep -q 'inet '; then
        log "Endereco IPv4 detectado na interface $iface."
    else
        log "AVISO: interface sem endereco IPv4."
    fi

    if has_internet; then
        echo "Internet: DISPONIVEL"
        log "Conectividade externa confirmada."
    else
        echo "Internet: NAO CONFIRMADA"
        log "Wi-Fi conectado, mas acesso externo nao confirmado."
    fi
}

main() {
    ensure_packages
    start_networkmanager
    enable_wifi

    select_network || {
        log "Operacao cancelada pelo usuario."
        exit 0
    }

    connect_wifi "$SELECTED_SSID" ||
        die "Falha ao conectar a rede selecionada."

    echo
    echo "Processo concluido."
    echo "Log:    $LOG_FILE"
    echo "Backup: $BACKUP_DIR"
    echo "Cache:  $DEB_DIR"
}

main "$@"
