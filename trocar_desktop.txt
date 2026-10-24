#!/bin/bash
# ==============================================================================
# Script: muda-ambientes.sh
# Descrição: Gerenciador independente de ambientes (LXQt / GNOME / KDE / Cinnamon / XFCE / MATE com Pacotes Oficiais Noble Numbat)
# Compatibilidade: Bash 3.x+ (Ubuntu/Xubuntu 24.04 LTS Noble Numbat)
# ==============================================================================

if [ "$EUID" -ne 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "[ERRO CRÍTICO] Este utilitário deve ser executado como root (sudo)." >&2
    exit 1
fi

LOG_FILE="/var/log/muda-ambientes.log"

cleanup_trap() {
    echo ""
    echo "[AVISO] Operação cancelada pelo usuário ou falha capturada." >&2
    rm -f /tmp/muda_lock 2>/dev/null
    exit 1
}
trap cleanup_trap INT TERM

if [ -f /tmp/muda_lock ]; then
    echo "[ERRO CRÍTICO] Já existe uma instância deste script em execução." >&2
    exit 1
fi
touch /tmp/muda_lock

cleanup_normal() {
    rm -f /tmp/muda_lock 2>/dev/null
}
trap cleanup_normal EXIT

exec 3>&1 4>&2
exec 1> >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo " [INICIALIZAÇÃO] $(date)"
echo " Log de execução: $LOG_FILE"
echo "=================================================="

detectar_gerenciador() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        CMD_UPDATE="apt-get update -y"
        CMD_INSTALL="apt-get install -y --no-install-recommends"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
        CMD_UPDATE="pacman -Sy"
        CMD_INSTALL="pacman -S --noconfirm"
    else
        echo "[ERRO CRÍTICO] Nenhum gerenciador de pacotes suportado foi encontrado." >&2
        exit 1
    fi
    echo "[AUDITORIA] Gerenciador validado: $PKG_MGR"
}

verificar_ou_instalar() {
    local pacote="$1"
    local pacote_alternativo="${2:-}"
    
    if [ "$PKG_MGR" = "apt" ]; then
        if dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null | grep -q "install ok installed"; then
            echo "[VERIFICAÇÃO] Componente '$pacote' já instalado."
            return 0
        fi
    elif [ "$PKG_MGR" = "pacman" ]; then
        if pacman -Qi "$pacote" >/dev/null 2>&1; then
            echo "[VERIFICAÇÃO] Componente '$pacote' já instalado."
            return 0
        fi
    fi

    echo "[DEPLOY] Instalando componente: $pacote..."
    $CMD_INSTALL "$pacote" >/dev/null 2>&1 || {
        echo "[AVISO] Falha ao instalar '$pacote'. Sincronizando repositórios..."
        $CMD_UPDATE >/dev/null 2>&1
        $CMD_INSTALL "$pacote" >/dev/null 2>&1 || {
            if [ -n "$pacote_alternativo" ]; then
                echo "[AVISO] Tentando pacote alternativo: $pacote_alternativo"
                $CMD_INSTALL "$pacote_alternativo" >/dev/null 2>&1 || {
                    echo "[AVISO] Pacote secundário '$pacote_alternativo' indisponível, ignorando..."
                }
            else
                echo "[AVISO] Pacote não crítico '$pacote' indisponível no repositório atual, prosseguindo..."
            fi
        }
    }
}

configurar_display_manager_limpo() {
    local alvo_sessao="$1"
    echo "[CONFIGURAÇÃO] Configurando LightDM para a sessão principal: $alvo_sessao"
    
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat <<EOF > /etc/lightdm/lightdm.conf.d/10-greeter-sessions.conf
[Seat:*]
greeter-show-sessions=true
greeter-show-manual-login=false
allow-guest=false
user-session=$alvo_sessao
EOF

    if [ ! -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
        cat <<EOF > /etc/lightdm/lightdm-gtk-greeter.conf
[greeter]
indicators = ~host;~spacer;~clock;~spacer;~session;~power;~language
theme-name = Adwaita
icon-theme-name = gnome
font-name = Sans 10
hide-user-image = false
xfce-session = false
EOF
    fi

    if [ -d /var/lib/AccountsService/users ]; then
        for user_file in /var/lib/AccountsService/users/*; do
            [ -f "$user_file" ] && sed -i 's/^Session=.*/Session=/' "$user_file" 2>/dev/null || true
        done
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl set-default graphical.target >/dev/null 2>&1 || true
        systemctl unmask lightdm.service >/dev/null 2>&1 || true
        systemctl enable lightdm.service >/dev/null 2>&1 || true
    fi
}

# 1. Opção LXQt
executar_lxqt_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: LXQT"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "xserver-xorg-core"
        verificar_ou_instalar "x11-xserver-utils"
        verificar_ou_instalar "libgl1-mesa-dri"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "openbox"
        verificar_ou_instalar "lxqt-core"
        verificar_ou_instalar "lxqt-session"
        verificar_ou_instalar "pcmanfm-qt"
        verificar_ou_instalar "lxqt-panel"
        verificar_ou_instalar "oxygen-icon-theme" "adwaita-icon-theme"

        mkdir -p /usr/share/xsessions
        cat <<EOF > /usr/share/xsessions/lxqt.desktop
[Desktop Entry]
Name=LXQt
Comment=LXQt Desktop Environment
Exec=startlxqt
TryExec=startlxqt
Type=Application
DesktopNames=LXQt
X-LightDM-DesktopName=LXQt
EOF

        if [ ! -f /usr/share/xsessions/lxqt-session.desktop ]; then
            ln -s /usr/share/xsessions/lxqt.desktop /usr/share/xsessions/lxqt-session.desktop 2>/dev/null || true
        fi

        mkdir -p /etc/xdg/lxqt
        cat <<EOF > /etc/xdg/lxqt/session.conf
[General]
window_manager=openbox

[Session]
window_manager=openbox
EOF

        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm >/dev/null 2>&1 || true
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "openbox"
        verificar_ou_instalar "lxqt"
        verificar_ou_instalar "lxqt-session"
    fi

    configurar_display_manager_limpo "lxqt"
    echo "[SUCESSO ABSOLUTO] LXQt configurado com sucesso."
}

# 2. Opção GNOME
executar_gnome_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: GNOME"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "gnome-session"
        verificar_ou_instalar "gnome-shell"
        verificar_ou_instalar "gnome-terminal"
        verificar_ou_instalar "nautilus"
        verificar_ou_instalar "dbus-x11"

        mkdir -p /usr/share/xsessions
        rm -f /usr/share/xsessions/gnome-xorg.desktop 2>/dev/null || true
        cat <<EOF > /usr/share/xsessions/gnome.desktop
[Desktop Entry]
Name=GNOME
Comment=Esta sessão inicia o GNOME via X11
Exec=env GNOME_SHELL_SESSION_MODE=classic gnome-session --session=gnome
TryExec=gnome-shell
Type=Application
DesktopNames=GNOME
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "gnome"
        verificar_ou_instalar "gnome-extra"
    fi

    configurar_display_manager_limpo "gnome"
    echo "[SUCESSO ABSOLUTO] GNOME configurado com sucesso."
}

# 3. Opção KDE Plasma
executar_kde_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: KDE PLASMA"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "kde-plasma-desktop" "plasma-desktop"
        verificar_ou_instalar "konsole"
        verificar_ou_instalar "dolphin"

        mkdir -p /usr/share/xsessions
        cat <<EOF > /usr/share/xsessions/plasma.desktop
[Desktop Entry]
Name=KDE Plasma
Comment=KDE Plasma Workspace
Exec=startplasma-x11
Type=Application
DesktopNames=KDE
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "plasma"
        verificar_ou_instalar "konsole"
    fi

    configurar_display_manager_limpo "plasma"
    echo "[SUCESSO ABSOLUTO] KDE Plasma configurado com sucesso."
}

# 4. Opção Cinnamon
executar_cinnamon_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: CINNAMON"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "cinnamon"
        verificar_ou_instalar "gnome-terminal"
        verificar_ou_instalar "nemo"

        mkdir -p /usr/share/xsessions
        cat <<EOF > /usr/share/xsessions/cinnamon.desktop
[Desktop Entry]
Name=Cinnamon
Comment=This session logs you into Cinnamon
Exec=cinnamon-session
TryExec=cinnamon
Type=Application
DesktopNames=Cinnamon
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "cinnamon"
    fi

    configurar_display_manager_limpo "cinnamon"
    echo "[SUCESSO ABSOLUTO] Cinnamon configurado com sucesso."
}

# 5. Opção XFCE
executar_xfce_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: XFCE"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "xfwm4"
        verificar_ou_instalar "xfce4-session"
        verificar_ou_instalar "xfce4-panel"
        verificar_ou_instalar "xfce4-terminal"
        verificar_ou_instalar "thunar"

        mkdir -p /usr/share/xsessions
        rm -f /usr/share/xsessions/xfce4.desktop 2>/dev/null || true
        cat <<EOF > /usr/share/xsessions/xfce.desktop
[Desktop Entry]
Name=XFCE
Comment=Use este ambiente para iniciar o XFCE Session
Exec=xfce4-session
TryExec=xfce4-session
Type=Application
DesktopNames=XFCE
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "xfce4"
        verificar_ou_instalar "xfce4-goodies"

        mkdir -p /usr/share/xsessions
        cat <<EOF > /usr/share/xsessions/xfce.desktop
[Desktop Entry]
Name=XFCE
Comment=Use este ambiente para iniciar o XFCE Session
Exec=xfce4-session
TryExec=xfce4-session
Type=Application
DesktopNames=XFCE
EOF
    fi

    configurar_display_manager_limpo "xfce"
    echo "[SUCESSO ABSOLUTO] XFCE configurado com sucesso."
}

# 6. Opção MATE (Com o nome oficial exato do pacote do Brisk Menu no Ubuntu 24.04: mate-applet-brisk-menu)
executar_mate_independente() {
    echo "=================================================="
    echo " [EXECUÇÃO] ROTINA INDEPENDENTE: MATE (OFICIAL NOBLE)"
    echo "=================================================="
    detectar_gerenciador
    $CMD_UPDATE >/dev/null 2>&1

    if [ "$PKG_MGR" = "apt" ]; then
        verificar_ou_instalar "xserver-xorg"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "mate-desktop-environment-core" "mate-desktop-environment"
        verificar_ou_instalar "mate-applets"
        verificar_ou_instalar "libmate-menu2"
        verificar_ou_instalar "mate-applet-brisk-menu"
        verificar_ou_instalar "mate-notification-daemon"
        verificar_ou_instalar "mate-terminal"
        verificar_ou_instalar "caja"
        verificar_ou_instalar "marco"
        verificar_ou_instalar "dbus-x11"
        verificar_ou_instalar "mate-polkit"
        verificar_ou_instalar "ayatana-indicator-application"

        mkdir -p /usr/share/xsessions
        rm -f /usr/share/xsessions/mate-session.desktop 2>/dev/null || true
        cat <<EOF > /usr/share/xsessions/mate.desktop
[Desktop Entry]
Name=MATE
Comment=Esta sessão inicia o MATE Desktop com Brisk Menu oficial
Exec=mate-session
TryExec=mate-session
Type=Application
DesktopNames=MATE
X-LightDM-DesktopName=MATE
EOF
    else
        verificar_ou_instalar "xorg-server"
        verificar_ou_instalar "lightdm"
        verificar_ou_instalar "lightdm-gtk-greeter"
        verificar_ou_instalar "mate"
        verificar_ou_instalar "mate-extra"
        verificar_ou_instalar "mate-applet-brisk-menu"

        mkdir -p /usr/share/xsessions
        cat <<EOF > /usr/share/xsessions/mate.desktop
[Desktop Entry]
Name=MATE
Comment=Esta sessão inicia o MATE Desktop com Brisk Menu oficial
Exec=mate-session
TryExec=mate-session
Type=Application
DesktopNames=MATE
EOF
    fi

    configurar_display_manager_limpo "mate"
    echo "[SUCESSO ABSOLUTO] MATE configurado com sucesso."
}

# 7. Opção Reboot
executar_reboot() {
    echo "[REBOOT] Sincronizando dados em disco e reiniciando em 3 segundos..."
    sync
    sleep 3
    reboot
}

# Menu Principal Interativo (8 opções)
while true; do
    echo ""
    echo "=================================================="
    echo "       GERENCIADOR SÊNIOR DE AMBIENTES - UNIX"
    echo "=================================================="
    echo "1 - Trocar para LXQt"
    echo "2 - Trocar para GNOME"
    echo "3 - Trocar para KDE Plasma"
    echo "4 - Trocar para Cinnamon"
    echo "5 - Trocar para XFCE"
    echo "6 - Trocar para MATE"
    echo "7 - Reboot do Sistema"
    echo "8 - Sair"
    echo "=================================================="
    printf "Selecione a opção desejada [1-8]: "
    read opcao

    case "$opcao" in
        1)
            executar_lxqt_independente
            ;;
        2)
            executar_gnome_independente
            ;;
        3)
            executar_kde_independente
            ;;
        4)
            executar_cinnamon_independente
            ;;
        5)
            executar_xfce_independente
            ;;
        6)
            executar_mate_independente
            ;;
        7)
            executar_reboot
            ;;
        8)
            echo "[ENCERRANDO] Nenhuma alteração pendente. Até logo!"
            exit 0
            ;;
        *)
            echo "[ERRO] Opção inválida! Digite estritamente um número entre 1 e 8."
            ;;
    esac
done
