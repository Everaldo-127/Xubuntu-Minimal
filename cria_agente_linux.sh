#!/bin/bash
# ============================================================
# Assistente Linux - Instalador e configurador
# Versão 34: exibição local integral de anexos e progresso persistente
# imediatamente após backup, antes da primeira fase.
# ============================================================

set -Eeuo pipefail

APP_DIR="$HOME/LinuxSupportAgent"
BACKUP_DIR="$APP_DIR/backups/install_$(date +%Y%m%d_%H%M%S)"
APP_FILE="$APP_DIR/linux_support_agent.py"
LAUNCHER="$APP_DIR/iniciar.sh"
CODEX_FILE="$APP_DIR/codex-path.txt"
LOGIN_SCRIPT="$APP_DIR/login-codex.sh"
HISTORY_DIR="$APP_DIR/historico"
DESKTOP_DIR=""

mkdir -p "$APP_DIR" "$HISTORY_DIR" "$BACKUP_DIR" "$APP_DIR/logs"
chmod 700 "$HISTORY_DIR" 2>/dev/null || true

# ============================================================
# CORES
# ============================================================
if [ -t 2 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'
    IS_TTY=1
else
    C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
    IS_TTY=0
fi

# ============================================================
# LOG
# ============================================================
LOG_FILE=""
try_log() { local c="$1"; if touch "$c" 2>/dev/null; then LOG_FILE="$c"; return 0; fi; return 1; }
if [ -w /var/log ]; then try_log "/var/log/assistente-linux-install.log" || true; fi
if [ -z "$LOG_FILE" ] && sudo -n true 2>/dev/null; then
    if sudo -n touch "/var/log/assistente-linux-install.log" 2>/dev/null && \
       sudo -n chown "$(id -un):$(id -gn)" "/var/log/assistente-linux-install.log" 2>/dev/null; then
        LOG_FILE="/var/log/assistente-linux-install.log"
    fi
fi
if [ -z "$LOG_FILE" ]; then try_log "$APP_DIR/logs/assistente-linux-install.log" || true; fi

BAR_DRAWN=0

clear_bar() {
    if [ "$IS_TTY" -eq 1 ] && [ "$BAR_DRAWN" -eq 1 ]; then
        printf "\r\033[K" >&2
    fi
}

log() {
    local level="$1"; shift
    local msg="$*"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    if [ -n "$LOG_FILE" ]; then printf '%s\n' "$line" >> "$LOG_FILE"; fi
    clear_bar
    local color=""
    case "$level" in
        INFO)  color="$C_CYAN" ;;
        OK)    color="$C_GREEN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
    esac
    printf "%s%s%s\n" "$color" "$line" "$C_RESET" >&2
    # Em terminal interativo, redesenha as barras após cada log para que
    # permaneçam sempre na última linha enquanto as fases avançam.
    if [ "$IS_TTY" -eq 1 ] && [ "$BAR_DRAWN" -eq 1 ]; then
        draw_bar
    fi
}

# ============================================================
# BARRA DE PROGRESSO
# ============================================================
PROGRESS_TOTAL=8
PROGRESS_CURRENT=0
PROGRESS_WIDTH=24
PHASE_WIDTH=16
PHASE_PERCENT=0
PHASE_NUMBER=0
PROGRESS_DESC="Aguardando início das etapas..."
PROGRESS_START_TS=$(date +%s)

format_elapsed() {
    local secs=$1
    printf "%02d:%02d" $((secs / 60)) $((secs % 60))
}

draw_bar() {
    [ "$IS_TTY" -eq 1 ] || return 0
    local pct=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))
    [ "$pct" -gt 100 ] && pct=100
    [ "$PHASE_PERCENT" -gt 100 ] && PHASE_PERCENT=100
    local filled=$(( pct * PROGRESS_WIDTH / 100 ))
    local empty=$(( PROGRESS_WIDTH - filled ))
    local phase_filled=$(( PHASE_PERCENT * PHASE_WIDTH / 100 ))
    local phase_empty=$(( PHASE_WIDTH - phase_filled ))
    local fill empty_str phase_fill phase_empty_str
    fill="$(printf '%*s' "$filled" '' | tr ' ' '█')"
    empty_str="$(printf '%*s' "$empty" '' | tr ' ' '░')"
    phase_fill="$(printf '%*s' "$phase_filled" '' | tr ' ' '█')"
    phase_empty_str="$(printf '%*s' "$phase_empty" '' | tr ' ' '░')"
    local elapsed=$(( $(date +%s) - PROGRESS_START_TS ))

    if [ "$BAR_DRAWN" -eq 0 ]; then
        printf "\n" >&2
        BAR_DRAWN=1
    else
        printf "\r" >&2
    fi
    printf "\033[K${C_CYAN}Geral [%s%s] %3d%%${C_RESET}  ${C_GREEN}Fase %d/8 [%s%s] %3d%%${C_RESET}  ${C_GRAY}%s${C_RESET}  %s" \
        "$fill" "$empty_str" "$pct" "$PHASE_NUMBER" "$phase_fill" "$phase_empty_str" "$PHASE_PERCENT" \
        "$(format_elapsed "$elapsed")" "$PROGRESS_DESC" >&2
}

set_progress() {
    PROGRESS_CURRENT="$1"
    PROGRESS_DESC="$2"
    draw_bar
}

progress_begin() {
    local n="$1" desc="$2"
    PHASE_NUMBER=$((n + 1))
    PHASE_PERCENT=0
    log "INFO" "[$((n + 1))/8] INÍCIO — $desc"
    PROGRESS_DESC="$desc"
    set_progress "$n" "$desc"
}

progress_done() {
    local n="$1"
    PHASE_NUMBER=$((n + 1))
    PHASE_PERCENT=100
    PROGRESS_CURRENT=$((n + 1))
    PROGRESS_DESC="Fase $((n + 1))/8 concluída"
    log "OK" "[$((n + 1))/8] fase concluída."
    draw_bar
}

# ============================================================
# INÍCIO
# ============================================================
if [ ! -f /etc/os-release ]; then
    echo "[ERROR] /etc/os-release ausente." >&2
    exit 1
fi
. /etc/os-release

printf "\n${C_BOLD}${C_CYAN}════════════════════════════════════════════════════════════${C_RESET}\n" >&2
printf "${C_BOLD}${C_CYAN}  ASSISTENTE LINUX — INSTALADOR v34${C_RESET}\n" >&2
printf "${C_BOLD}${C_CYAN}════════════════════════════════════════════════════════════${C_RESET}\n" >&2
printf "  ${C_GRAY}Distribuição:${C_RESET} ${PRETTY_NAME:-Linux}\n" >&2
printf "  ${C_GRAY}Log:         ${C_RESET} ${LOG_FILE:-<desabilitado>}\n" >&2
printf "  ${C_GRAY}Backup:      ${C_RESET} $BACKUP_DIR\n" >&2
printf "\n" >&2

log "INFO" "Iniciando instalação do Assistente Linux (v34)"

# ============================================================
# SUDO -v
# ============================================================
if [ "$(id -u)" -eq 0 ]; then
    log "WARN" "Executando como root. Recomendado rodar como usuário normal."
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    printf "${C_YELLOW}→ Será solicitada a senha do sudo AGORA, uma única vez.${C_RESET}\n" >&2
    printf "${C_YELLOW}  Depois disso, o script não pedirá mais senha por 15 minutos.${C_RESET}\n\n" >&2
    if ! sudo -v; then
        log "ERROR" "Falha ao validar sudo."
        exit 1
    fi
    SUDO="sudo"
    log "OK" "sudo validado. Prosseguindo..."
else
    log "ERROR" "sudo não encontrado. Impossível prosseguir."
    exit 1
fi

if [ -n "${SUDO:-}" ]; then
    ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
fi

# ============================================================
# BACKUP
# ============================================================
if [ -f "$APP_FILE" ]; then
    cp -a "$APP_FILE" "${APP_FILE}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    log "OK" "Backup do app anterior criado."
fi
if [ -r "$0" ]; then
    INSTALLER_BACKUP="$BACKUP_DIR/installer_$(date +%Y%m%d_%H%M%S).sh"
    if cp -p "$0" "$INSTALLER_BACKUP" 2>/dev/null; then
        chmod 600 "$INSTALLER_BACKUP" 2>/dev/null || true
        log "OK" "Backup do instalador criado em $INSTALLER_BACKUP"
    else
        log "WARN" "Não foi possível copiar o instalador para o backup."
    fi
fi
if [ -d "$APP_DIR" ]; then
    if tar -czf "$BACKUP_DIR/app_backup.tar.gz" --exclude="LinuxSupportAgent/backups" -C "$HOME" "LinuxSupportAgent" 2>/dev/null; then
        chmod 600 "$BACKUP_DIR/app_backup.tar.gz" 2>/dev/null || true
        log "OK" "Backup do diretório criado em $BACKUP_DIR"
    else
        log "WARN" "Não foi possível criar o arquivo compactado do aplicativo."
    fi
fi

# *** AQUI: desenha a barra em 0% IMEDIATAMENTE após o backup,
# antes de qualquer fase. Assim a última linha é a barra. ***
set_progress 0 "Aguardando início das etapas..."

# ============================================================
# FASE 0 — AppArmor (correção do sudo test + tolerância a erro)
# ============================================================
progress_begin 0 "Fase 1/8 — Correção do sandbox AppArmor"

fix_codex_apparmor_sandbox() {
    local is_ubuntu=0
    if [ "${ID:-}" = "ubuntu" ] || [ "${ID_LIKE:-}" = "ubuntu" ] || [ "${ID:-}" = "debian" ]; then is_ubuntu=1; fi
    local userns_restricted=0
    if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
        [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] && userns_restricted=1
    fi
    if [ "$is_ubuntu" -eq 0 ] || [ "$userns_restricted" -eq 0 ]; then
        log "INFO" "[1/8] AppArmor userns não restrito ou distro não aplicável. Pulando."
        return 0
    fi

    log "INFO" "[1/8] Detectado Ubuntu com AppArmor restringindo userns."

    local codex_candidate=""
    if [ -f "$CODEX_FILE" ]; then codex_candidate="$(cat "$CODEX_FILE" 2>/dev/null || true)"; fi
    if [ -z "$codex_candidate" ] || [ ! -x "$codex_candidate" ]; then
        command -v codex >/dev/null 2>&1 && codex_candidate="$(command -v codex)"
    fi
    if [ -z "$codex_candidate" ] || [ ! -x "$codex_candidate" ]; then
        for C in "$HOME/.local/bin/codex" "$HOME/.codex/bin/codex" "$HOME/.npm-global/bin/codex" "/usr/local/bin/codex" "/usr/bin/codex"; do
            [ -x "$C" ] && { codex_candidate="$C"; break; }
        done
    fi
    if [ -z "$codex_candidate" ] || [ ! -x "$codex_candidate" ]; then
        log "WARN" "[1/8] Codex ainda não instalado. Correção será tentada na fase 2."
        return 0
    fi

    local real_codex; real_codex="$(readlink -f "$codex_candidate" 2>/dev/null || echo "$codex_candidate")"
    log "INFO" "[1/8] Binário do Codex: $real_codex"

    local APPARMOR_PROFILE="/etc/apparmor.d/codex-native"
    local APPARMOR_BACKUP_DIR="$BACKUP_DIR/apparmor"
    mkdir -p "$APPARMOR_BACKUP_DIR" 2>/dev/null || true

    # CORREÇÃO: não usar $SUDO test (test é builtin). Só o cp/install/parser rodam via sudo.
    local profile_exists=0
    [ -f "$APPARMOR_PROFILE" ] && profile_exists=1

    if [ "$profile_exists" -eq 1 ]; then
        if $SUDO grep -qF "$real_codex" "$APPARMOR_PROFILE" 2>/dev/null; then
            log "INFO" "[1/8] Perfil já existe. Recarregando..."
            $SUDO apparmor_parser -r "$APPARMOR_PROFILE" 2>/dev/null || \
                log "WARN" "[1/8] apparmor_parser retornou erro."
            return 0
        fi
        $SUDO cp -a "$APPARMOR_PROFILE" "$APPARMOR_BACKUP_DIR/codex-native.bak" 2>/dev/null || true
    fi

    local tmp_profile; tmp_profile="$(mktemp)"
    cat > "$tmp_profile" <<EOF
abi <abi/4.0>,
include <tunables/global>

profile codex-native $real_codex flags=(unconfined) {
  userns,
  $real_codex mr,

  include if exists <local/codex-native>
}
EOF
    if ! $SUDO install -m 0644 "$tmp_profile" "$APPARMOR_PROFILE" 2>/dev/null; then
        log "WARN" "[1/8] Não foi possível gravar o perfil AppArmor."
        rm -f "$tmp_profile"
        return 0
    fi
    rm -f "$tmp_profile"
    log "OK" "[1/8] Perfil criado em $APPARMOR_PROFILE"

    if $SUDO apparmor_parser -r "$APPARMOR_PROFILE" 2>/dev/null; then
        log "OK" "[1/8] Perfil AppArmor carregado."
    else
        log "WARN" "[1/8] Falha ao carregar perfil (não crítico)."
    fi

    if "$real_codex" --enable use_legacy_landlock sandbox linux /bin/true >/dev/null 2>&1; then
        log "OK" "[1/8] Teste do sandbox: OK."
    else
        log "WARN" "[1/8] Teste do sandbox landlock falhou."
    fi
    return 0
}

fix_codex_apparmor_sandbox || log "WARN" "Fase 0 retornou erro; prosseguindo."
progress_done 0

# ============================================================
# FASE 1 — Dependências
# ============================================================
progress_begin 1 "Fase 2/8 — Instalação de dependências"

log "INFO" "[2/8] Verificando gerenciador de pacotes..."
install_dependencies() {
    local deps_apt="python3 python3-tk curl ca-certificates xdg-utils xdg-user-dirs xterm desktop-file-utils"
    local deps_dnf="python3 python3-tkinter curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_pacman="python tk curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_zypper="python3 python3-tkinter curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_apk="python3 py3-tkinter curl ca-certificates xdg-utils xterm"

    if command -v apt-get >/dev/null 2>&1; then
        log "INFO" "[2/8] Executando apt-get update (pode demorar)..."
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
        log "OK" "[2/8] apt-get update concluído."
        log "INFO" "[2/8] Instalando pacotes via apt-get..."
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $deps_apt
    elif command -v dnf >/dev/null 2>&1; then
        log "INFO" "[2/8] Instalando via dnf..."
        $SUDO dnf install -y $deps_dnf
    elif command -v yum >/dev/null 2>&1; then
        log "INFO" "[2/8] Instalando via yum..."
        $SUDO yum install -y $deps_dnf
    elif command -v pacman >/dev/null 2>&1; then
        log "INFO" "[2/8] Instalando via pacman..."
        $SUDO pacman -Sy --needed --noconfirm $deps_pacman
    elif command -v zypper >/dev/null 2>&1; then
        log "INFO" "[2/8] Instalando via zypper..."
        $SUDO zypper --non-interactive install $deps_zypper
    elif command -v apk >/dev/null 2>&1; then
        log "INFO" "[2/8] Instalando via apk..."
        $SUDO apk add $deps_apk
    else
        log "ERROR" "Gerenciador não reconhecido."; exit 1
    fi
    log "OK" "[2/8] Dependências instaladas."
}
install_dependencies
mkdir -p "$HOME/.local/share/applications"
progress_done 1

# ============================================================
# FASE 2 — Codex
# ============================================================
progress_begin 2 "Fase 3/8 — Localização do Codex CLI"

CODEX_BIN=""
if [ -f "$CODEX_FILE" ]; then SAVED_CODEX="$(cat "$CODEX_FILE" 2>/dev/null || true)"; if [ -n "$SAVED_CODEX" ] && [ -x "$SAVED_CODEX" ]; then CODEX_BIN="$SAVED_CODEX"; log "OK" "[3/8] Codex encontrado (registrado): $CODEX_BIN"; fi; fi
if [ -z "$CODEX_BIN" ] && command -v codex >/dev/null 2>&1; then CODEX_BIN="$(command -v codex)"; log "OK" "[3/8] Codex encontrado (PATH): $CODEX_BIN"; fi
if [ -z "$CODEX_BIN" ]; then
    for C in "$HOME/.local/bin/codex" "$HOME/.codex/bin/codex" "$HOME/.npm-global/bin/codex" "/usr/local/bin/codex" "/usr/bin/codex"; do
        if [ -x "$C" ]; then CODEX_BIN="$C"; log "OK" "[3/8] Codex encontrado em: $CODEX_BIN"; break; fi
    done
fi
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    log "WARN" "[3/8] Codex não encontrado. Baixando instalador..."
    TMP="$(mktemp)"
    if curl -fsSL -o "$TMP" https://chatgpt.com/codex/install.sh && [ -s "$TMP" ]; then
        log "INFO" "[3/8] Executando instalador do Codex..."
        sh "$TMP"
    else
        log "ERROR" "Falha ao baixar."
    fi
    rm -f "$TMP"
    export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
    if command -v codex >/dev/null 2>&1; then CODEX_BIN="$(command -v codex)"; fi
fi
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then log "ERROR" "Codex não encontrado."; exit 1; fi
printf '%s\n' "$CODEX_BIN" > "$CODEX_FILE"
log "OK" "[3/8] Codex registrado em $CODEX_FILE"

if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
   [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
    if ! $SUDO grep -qF "$(readlink -f "$CODEX_BIN")" "/etc/apparmor.d/codex-native" 2>/dev/null; then
        log "INFO" "[3/8] Codex recém-instalado. Reaplicando perfil AppArmor..."
        fix_codex_apparmor_sandbox || log "WARN" "Reaplicação falhou."
    fi
fi
progress_done 2

# ============================================================
# FASE 3 — App Python
# ============================================================
progress_begin 3 "Fase 4/8 — Criação do aplicativo Python"

log "INFO" "[4/8] Gravando linux_support_agent.py..."

cat > "$APP_FILE" <<'PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, json, uuid, tempfile, subprocess, threading, re, shutil
from pathlib import Path
from datetime import datetime
from shutil import which
import tkinter as tk
from tkinter import messagebox, filedialog

APP_DIR = Path.home() / "LinuxSupportAgent"
CODEX_FILE = APP_DIR / "codex-path.txt"
LOGIN_SCRIPT = APP_DIR / "login-codex.sh"
HISTORY_DIR = APP_DIR / "historico"
TEMP_ATTACH_DIR = APP_DIR / "temp_attachments"
APP_TITLE = "Assistente Linux"

MAX_HISTORY_SESSIONS = 50
CODEX_CHAR_LIMIT = 1048576
PROMPT_SAFETY_MARGIN = 50000
MAX_PROMPT_CHARS = CODEX_CHAR_LIMIT - PROMPT_SAFETY_MARGIN

APP_DIR.mkdir(parents=True, exist_ok=True)
HISTORY_DIR.mkdir(parents=True, exist_ok=True)
TEMP_ATTACH_DIR.mkdir(parents=True, exist_ok=True)
try: HISTORY_DIR.chmod(0o700)
except OSError: pass

codex_path = ""
request_running = False
login_terminal_open = False
current_session = None
attached_files = []
persona_confirmed_session_id = None
active_session_id = None
search_filter = ""
sidebar_index_map = []
selected_index = None
codex_thread_id = None

CODEX_LANDLOCK_ARGS = ["--enable", "use_legacy_landlock"]

# ---------- HISTÓRICO ----------
def now_iso(): return datetime.now().astimezone().isoformat(timespec="seconds")
def format_date(value):
    try: return datetime.fromisoformat(value).astimezone().strftime("%d/%m/%Y %H:%M")
    except (ValueError, TypeError): return "Data desconhecida"
def session_file(sid):
    try: uuid.UUID(sid)
    except (ValueError, TypeError, AttributeError): raise ValueError("ID inválido.")
    return HISTORY_DIR / f"{sid}.json"

def rotate_history():
    files = sorted(HISTORY_DIR.glob("*.json"), key=lambda p: p.stat().st_mtime)
    excess = len(files) - MAX_HISTORY_SESSIONS
    if excess > 0:
        for old in files[:excess]:
            try: old.unlink()
            except OSError: pass

def save_session(session):
    if not session: return
    session["updated_at"] = now_iso()
    target = session_file(session["id"])
    fd, tmp = tempfile.mkstemp(prefix=".hist-", suffix=".tmp", dir=str(HISTORY_DIR))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(session, f, ensure_ascii=False, indent=2); f.write("\n")
        os.chmod(tmp, 0o600); os.replace(tmp, target)
        rotate_history()
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise

def load_session(sid):
    path = session_file(sid)
    with path.open("r", encoding="utf-8") as f: session = json.load(f)
    if not isinstance(session, dict) or session.get("id") != sid or not isinstance(session.get("messages"), list): raise ValueError("Histórico inválido.")
    return session

def list_sessions():
    sessions = []
    for path in HISTORY_DIR.glob("*.json"):
        try:
            with path.open("r", encoding="utf-8") as f: s = json.load(f)
            if isinstance(s, dict) and isinstance(s.get("messages"), list) and isinstance(s.get("id"), str) and path.name == f"{s['id']}.json":
                sessions.append(s)
        except (OSError, ValueError, json.JSONDecodeError): continue
    sessions.sort(key=lambda x: x.get("updated_at", ""), reverse=True)
    return sessions

def delete_session(sid):
    path = session_file(sid)
    try:
        path.unlink(); return True
    except OSError:
        return False

def create_session(clear=True):
    global current_session, persona_confirmed_session_id, active_session_id, selected_index, codex_thread_id
    current_session = {"id": str(uuid.uuid4()), "title": "Nova conversa", "created_at": now_iso(), "updated_at": now_iso(), "messages": []}
    try: save_session(current_session)
    except OSError as exc: messagebox.showerror(APP_TITLE, f"Erro ao criar histórico:\n{exc}")
    persona_confirmed_session_id = None
    active_session_id = current_session["id"]
    codex_thread_id = None
    selected_index = None
    if clear:
        clear_answer_box()
        update_sidebar_history()
        if sidebar_listbox.size() > 0:
            sidebar_listbox.selection_clear(0, tk.END)
            sidebar_listbox.selection_set(0)
            selected_index = 0
        question_entry.focus_set()
        root.after(150, request_persona_confirmation)

def persist_message(role, content):
    global current_session
    if current_session is None: create_session()
    current_session["messages"].append({"role": role, "content": content, "time": now_iso()})
    if current_session.get("title") == "Nova conversa" and role == "user":
        current_session["title"] = (" ".join(content.split()))[:65] or "Nova conversa"
        update_sidebar_history()
    try: save_session(current_session)
    except OSError as exc: messagebox.showerror(APP_TITLE, f"Erro ao salvar histórico:\n{exc}")

# ---------- UI ----------
def clear_answer_box():
    answer_box.config(state="normal"); answer_box.delete("1.0", "end")
    insert_banner(); answer_box.config(state="disabled")

def insert_banner():
    answer_box.insert("end", "╔══════════════════════════════════════════════════════════╗\n", "banner")
    answer_box.insert("end", "║           🤖  ASSISTENTE LINUX  🤖                        ║\n", "banner")
    answer_box.insert("end", "╚══════════════════════════════════════════════════════════╝\n", "banner")
    answer_box.insert("end", "\n", "banner")
    answer_box.insert("end", "Especialidade: Suporte técnico Linux, diagnóstico de sistemas,\n", "banner_info")
    answer_box.insert("end", "administração, desenvolvimento de scripts Bash e automação.\n\n", "banner_info")

def insert_message(label, content, tag):
    answer_box.insert("end", f"  {label}  \n", f"header_{tag}")
    # Ao exibir um arquivo integral, preservar inclusive espaços e quebras de
    # linha finais. Também não inserir botões no meio do conteúdo original.
    is_full_file = content.startswith("CONTEÚDO COMPLETO DO ARQUIVO:")
    if is_full_file:
        answer_box.insert("end", content + "\n\n", tag)
    else:
        answer_box.insert("end", content.rstrip() + "\n\n", tag)
    if not is_full_file:
        process_copy_buttons()

def append_message(label, content, tag):
    answer_box.config(state="normal"); insert_message(label, content, tag); answer_box.config(state="disabled"); answer_box.see("end")

def display_session(session):
    clear_answer_box(); answer_box.config(state="normal")
    for m in session.get("messages", []):
        r, c = m.get("role", ""), m.get("content", "")
        if not isinstance(c, str): continue
        if r == "user": insert_message("Você", c, "user")
        elif r == "assistant": insert_message("Assistente Linux", c, "assistant")
        elif r == "error": insert_message("Erro", c, "error")
    answer_box.config(state="disabled"); answer_box.see("end")

def process_copy_buttons():
    text_content = answer_box.get("1.0", "end-1c")
    for match in re.finditer(r'```(\w*)\n(.*?)```', text_content, re.DOTALL):
        code = match.group(2).strip()
        if not code: continue
        idx = answer_box.search(match.group(0), "1.0", tk.END)
        if not idx: continue
        btn = tk.Button(answer_box, text="📋 Copiar código", font=("Sans", 8, "bold"),
                        bg="#e0e0e0", activebackground="#c0c0c0", relief="raised", bd=1,
                        command=lambda c=code: copy_to_clipboard(c))
        end_idx = f"{idx}+{len(match.group(0))}c"
        answer_box.window_create(end_idx, window=btn, padx=5, pady=2)
        answer_box.insert(end_idx, "\n")
    for match in re.finditer(r'^\s*(\$|#)\s+(.+)$', text_content, re.MULTILINE):
        cmd = match.group(2).strip()
        if not cmd: continue
        idx = answer_box.search(match.group(0), "1.0", tk.END)
        if not idx: continue
        btn = tk.Button(answer_box, text="⌨ Copiar comando", font=("Sans", 8, "bold"),
                        bg="#d0e8ff", activebackground="#a8d0f0", relief="raised", bd=1,
                        command=lambda c=cmd: copy_to_clipboard(c))
        end_idx = f"{idx}+{len(match.group(0))}c"
        answer_box.window_create(end_idx, window=btn, padx=5, pady=2)
        answer_box.insert(end_idx, "\n")

def copy_to_clipboard(text):
    root.clipboard_clear(); root.clipboard_append(text); set_status("Copiado!")

def truncate_title(title, limit=30):
    t = " ".join(str(title).split())
    return t if len(t) <= limit else t[:limit-3] + "..."

def build_filtered_sessions():
    sessions = list_sessions()
    if not search_filter:
        return sessions
    needle = search_filter.lower()
    return [s for s in sessions
            if needle in " ".join(str(s.get("title", "")).split()).lower()]

def update_sidebar_history():
    global sidebar_index_map, selected_index
    if 'sidebar_listbox' not in globals(): return
    prev_selected_id = None
    if selected_index is not None and 0 <= selected_index < len(sidebar_index_map):
        prev_selected_id = sidebar_index_map[selected_index]
    sidebar_listbox.delete(0, tk.END)
    sidebar_index_map = []
    filtered = build_filtered_sessions()
    for i, s in enumerate(filtered):
        t = truncate_title(s.get("title", "Conversa"), 30)
        sidebar_listbox.insert(tk.END, f"  {t}  ")
        sidebar_index_map.append(s.get("id"))
        if s.get("id") == active_session_id:
            sidebar_listbox.itemconfig(i, background="#f0ad4e", foreground="#000000",
                                        selectbackground="#f0ad4e", selectforeground="#000000")
        else:
            bg = "#1e7a3c" if i % 2 == 0 else "#1e5aa8"
            sidebar_listbox.itemconfig(i, background=bg, foreground="#ffffff",
                                        selectbackground="#f0ad4e", selectforeground="#000000")
    selected_index = None
    if prev_selected_id is not None:
        for i, sid in enumerate(sidebar_index_map):
            if sid == prev_selected_id:
                sidebar_listbox.selection_clear(0, tk.END)
                sidebar_listbox.selection_set(i)
                sidebar_listbox.activate(i)
                selected_index = i
                break
    if search_filter:
        set_status(f"{len(filtered)} conversa(s) encontrada(s) para '{search_filter}'.")

def on_sidebar_click(event=None):
    global selected_index
    sel = sidebar_listbox.curselection()
    if not sel:
        selected_index = None
        return
    selected_index = sel[0]
    if 0 <= selected_index < len(sidebar_index_map):
        sid = sidebar_index_map[selected_index]
        try:
            s = load_session(sid)
            title = s.get("title", "Conversa")
            set_status(f"Selecionada: {title}  |  Clique em 'Abrir' ou dê duplo clique para carregar.")
        except Exception:
            set_status("Selecionada.")

def on_sidebar_double_click(event=None):
    open_selected_session()

def open_selected_session():
    global current_session, active_session_id, codex_thread_id
    if request_running: set_status("Aguarde."); return
    sel = sidebar_listbox.curselection()
    if not sel:
        set_status("Selecione uma conversa e clique em 'Abrir'.")
        return
    idx = sel[0]
    if idx >= len(sidebar_index_map):
        set_status("Seleção inválida. Atualize a lista.")
        return
    sid = sidebar_index_map[idx]
    try:
        current_session = load_session(sid)
        active_session_id = current_session["id"]
        codex_thread_id = None
        display_session(current_session); update_sidebar_history()
        set_status("Conversa carregada."); question_entry.focus_set()
    except Exception as exc: messagebox.showerror(APP_TITLE, f"Erro ao abrir:\n{exc}")

def delete_selected_session():
    global current_session, active_session_id, selected_index, codex_thread_id
    if request_running: set_status("Aguarde."); return
    sel = sidebar_listbox.curselection()
    if not sel:
        set_status("Selecione uma conversa na lista antes de deletar.")
        messagebox.showinfo(APP_TITLE, "Clique sobre uma conversa na lista lateral para selecioná-la, e só depois clique em 'Deletar'.")
        return
    idx = sel[0]
    if idx >= len(sidebar_index_map):
        set_status("Seleção inválida. Atualize a lista.")
        return
    sid = sidebar_index_map[idx]
    try:
        target = load_session(sid)
    except Exception:
        target = {"id": sid, "title": "Conversa"}
    title = target.get("title", "Conversa")
    confirm = messagebox.askyesno(APP_TITLE, f"Deletar a conversa:\n\n{title}\n\nEsta ação não pode ser desfeita.")
    if not confirm: return
    if delete_session(sid):
        set_status(f"Conversa '{title}' deletada.")
        selected_index = None
        if active_session_id == sid:
            current_session = None
            active_session_id = None
            codex_thread_id = None
            create_session()
        else:
            update_sidebar_history()
    else:
        messagebox.showerror(APP_TITLE, "Não foi possível deletar a conversa.")

def on_search_change(*args):
    global search_filter
    search_filter = search_var.get().strip()
    update_sidebar_history()

def apply_search():
    global search_filter
    search_filter = search_var.get().strip()
    update_sidebar_history()
    if not search_filter:
        set_status("Pesquisa limpa. Mostrando todas as conversas.")
    else:
        n = len(build_filtered_sessions())
        set_status(f"Pesquisa aplicada: {n} conversa(s) encontrada(s).")

def clear_search():
    search_var.set("")
    apply_search()

# ---------- ANEXOS ----------
def attach_files():
    global attached_files
    files = filedialog.askopenfilenames(title="Anexar arquivos", filetypes=[
        ("Imagens", "*.png *.jpg *.jpeg *.gif *.webp"),
        ("Texto/Código", "*.txt *.py *.sh *.js *.html *.css *.json *.md *.log *.yaml *.yml *.toml *.conf *.cfg *.ini"),
        ("Todos", "*.*")])
    for f in files:
        if f not in attached_files: attached_files.append(f)
    update_attachment_display()

def update_attachment_display():
    if 'attachment_label' not in globals(): return
    if attached_files:
        names = [Path(f).name for f in attached_files]
        attachment_label.config(text=f"Anexos: {', '.join(names)}", fg="#0066cc")
        clear_attachments_btn.pack(side="left", padx=(5, 0))
    else:
        attachment_label.config(text="Nenhum arquivo anexado", fg="#888888")
        clear_attachments_btn.pack_forget()

def clear_attachments():
    global attached_files; attached_files = []; update_attachment_display()

def prepare_attachment_for_codex(path):
    src = Path(path)
    if not src.exists():
        return None
    safe_name = re.sub(r'[^\w\.-]', '_', src.name)
    dst = TEMP_ATTACH_DIR / f"{uuid.uuid4().hex[:8]}_{safe_name}"
    try:
        shutil.copy2(src, dst)
        return str(dst)
    except Exception:
        return None

def cleanup_temp_attachments():
    now = datetime.now().timestamp()
    try:
        for p in TEMP_ATTACH_DIR.glob("*"):
            try:
                if now - p.stat().st_mtime > 3600:
                    p.unlink()
            except OSError:
                pass
    except Exception:
        pass

# ---------- CODEX ----------
def locate_codex():
    cands = []
    try:
        s = CODEX_FILE.read_text(encoding="utf-8").strip()
        if s: cands.append(s)
    except OSError: pass
    d = which("codex")
    if d: cands.insert(0, d)
    cands.extend([str(Path.home() / ".local/bin/codex"), str(Path.home() / ".codex/bin/codex"), str(Path.home() / ".npm-global/bin/codex"), "/usr/local/bin/codex", "/usr/bin/codex"])
    for c in cands:
        if os.path.isfile(c) and os.access(c, os.X_OK): return c
    return None

def set_status(text): status_var.set(text)

def codex_authenticated():
    if not codex_path: return False
    try:
        r = subprocess.run([codex_path, "login", "status"], capture_output=True, text=True, timeout=20, check=False, env=os.environ.copy())
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired): return False

def find_terminal():
    for n in ("x-terminal-emulator", "xfce4-terminal", "gnome-terminal", "mate-terminal", "konsole", "lxterminal", "xterm"):
        f = which(n)
        if f: return n, f
    return None, None

def open_login_terminal():
    global login_terminal_open
    if login_terminal_open: return
    if codex_authenticated():
        login_terminal_open = False; send_button.config(state="normal"); question_entry.config(state="normal")
        set_status("Codex autenticado."); question_entry.focus_set()
        root.after(200, request_persona_confirmation)
        return
    tn, tp = find_terminal()
    if not tp:
        login_terminal_open = False; send_button.config(state="disabled"); question_entry.config(state="disabled")
        messagebox.showerror(APP_TITLE, "Nenhum terminal gráfico encontrado."); return
    login_terminal_open = True; set_status("Aguardando autenticação...")
    try:
        if tn == "gnome-terminal": cmd = [tp, "--", "bash", str(LOGIN_SCRIPT)]
        elif tn == "konsole": cmd = [tp, "-e", "bash", str(LOGIN_SCRIPT)]
        elif tn in ("xfce4-terminal", "mate-terminal"): cmd = [tp, "--disable-server", "--command", "bash " + subprocess.list2cmdline([str(LOGIN_SCRIPT)])]
        elif tn == "lxterminal": cmd = [tp, "-e", "bash", str(LOGIN_SCRIPT)]
        else: cmd = [tp, "-e", "bash", str(LOGIN_SCRIPT)]
        subprocess.Popen(cmd, env=os.environ.copy(), start_new_session=True)
    except OSError as exc:
        login_terminal_open = False; messagebox.showerror(APP_TITLE, f"Erro:\n{exc}"); return
    check_login()

def check_login():
    global login_terminal_open
    if not root.winfo_exists(): return
    if codex_authenticated():
        login_terminal_open = False; send_button.config(state="normal"); question_entry.config(state="normal")
        set_status("Codex autenticado."); question_entry.focus_set()
        root.after(200, request_persona_confirmation)
        return
    set_status("Aguardando login..."); root.after(3000, check_login)

# ---------- PERSONALIDADE ----------
SYSTEM_INSTRUCTIONS = """Nesta missão, atue como especialista linux com foco em desenvolvimento de scripts bash e suporte a sistemas Linux antigos e atuais, para desenvolvimento de shell scripts para automação de processos e gerenciamento de ambientes.

Antes de iniciar uma solicitação, sempre perguntar qual é a configuração atual do sistema para então gerar os scripts corretamente e / ou informar o comando correto para a distro (kernel) do sistema com o uname -a em ambientes Linux.

Após informado sobre qual o sistema atual, gerar o script executando antes de tudo o reconhecimento da versão atual do sistema, o repositório correto e os pacotes correspondentes corretos para o sistema detectado, assim como instalar os pacotes e modulos ausentes quando verificado a necessidade, e após isto, realizar sempre o back- up automatico do ambiente em todo script, antes de qualquer alteração no ambiente que possa comprometer o sistema e dar tela preta.

IDIOMA: Responda em português brasileiro, objetivo e técnico.
CONTINUIDADE: Considere o histórico anterior.
FONTES: Priorize documentação oficial. Não invente links ou versões.
SCRIPTS: Entregue scripts completos em um único bloco. Explique riscos de operações destrutivas.
SEGURANÇA: Não execute comandos no sistema do usuário; permaneça em modo somente leitura."""

def is_direct_attachment_display_request(question):
    """Identifica pedidos explícitos para reproduzir o conteúdo integral do anexo."""
    q = " ".join(str(question).lower().split())
    display_action = re.search(
        r"\b(mostr(?:e|ar|a)|exib(?:a|ir|e)|imprim(?:a|ir)|reproduz(?:a|ir)|"
        r"transcrev(?:a|er)|copi(?:e|ar)|traga|coloque|escrev(?:a|er))\b", q
    )
    content_target = re.search(
        r"(conte[uú]do|texto|conte[uú]do.{0,30}(?:arquivo|anexo)|"
        r"(?:arquivo|anexo).{0,40}(?:completo|integral|conte[uú]do|tela)|"
        r"na tela|completo|integral)", q
    )
    return bool(display_action and content_target)


def render_attached_file_contents(paths):
    """Lê e prepara a reprodução integral local, sem chamar o Codex ou cat."""
    blocks = []
    for path in paths:
        name = Path(path).name
        content, error = read_attachment_text(path)
        if error:
            blocks.append(f"Não foi possível exibir '{name}': {error}")
            continue
        # Não cortar, resumir ou enviar esse pedido ao modelo: o texto é mostrado
        # diretamente pela interface a partir dos bytes lidos pelo aplicativo.
        blocks.append(
            f"CONTEÚDO COMPLETO DO ARQUIVO: {name}\n"
            f"--- INÍCIO DO ARQUIVO: {name} ---\n"
            f"{content}"
            f"\n--- FIM DO ARQUIVO: {name} ---"
        )
    return "\n\n".join(blocks) if blocks else "Nenhum arquivo anexado para exibição."


def read_attachment_text(path):
    """Lê anexos textuais no próprio aplicativo, sem depender do sandbox do Codex."""
    p = Path(path)
    try:
        raw = p.read_bytes()
    except OSError as exc:
        return None, f"Não foi possível ler '{p.name}' no aplicativo: {exc}"
    if b"\x00" in raw[:8192]:
        return None, f"O anexo '{p.name}' parece ser binário; não foi convertido em texto."
    try:
        return raw.decode("utf-8-sig"), None
    except UnicodeDecodeError:
        try:
            return raw.decode("cp1252"), None
        except UnicodeDecodeError:
            return raw.decode("latin-1"), None

def build_prompt(question, previous_messages, attachment_paths):
    ctx_lines = []
    for m in previous_messages[-16:]:
        r, c = m.get("role", ""), m.get("content", "")
        if not isinstance(c, str):
            continue
        if r == "user":
            lbl = "USUÁRIO"
        elif r == "assistant":
            lbl = "ASSISTENTE"
        else:
            continue
        ctx_lines.append(f"{lbl}:\n{c[:8000]}")
    ctx = "\n\nHISTÓRICO:\n\n" + "\n\n".join(ctx_lines) if ctx_lines else "\n\nPrimeira pergunta."

    att_blocks = []
    if attachment_paths:
        for path in attachment_paths:
            content, error = read_attachment_text(path)
            name = Path(path).name
            if error:
                att_blocks.append(f"ARQUIVO ANEXADO: {name}\n[AVISO: {error}]")
            else:
                att_blocks.append(
                    f"CONTEÚDO INTEGRAL DO ARQUIVO ANEXADO: {name}\n"
                    "O conteúdo abaixo foi lido pelo aplicativo e está incorporado nesta solicitação. "
                    "Não execute cat nem tente acessar o arquivo pelo sandbox. Use exatamente este conteúdo.\n"
                    "--- INÍCIO DO ARQUIVO ---\n" + content +
                    "\n--- FIM DO ARQUIVO ---"
                )
    att_ctx = "\n\nANEXOS LIDOS PELO APLICATIVO:\n\n" + "\n\n".join(att_blocks) if att_blocks else ""
    request_ctx = "\n\nNOVA SOLICITAÇÃO:\n" + question

    # Mantém o conteúdo integral dos anexos e a pergunta. Se necessário, reduz
    # somente o histórico; nunca corta silenciosamente o arquivo anexado.
    full = SYSTEM_INSTRUCTIONS + ctx + att_ctx + request_ctx
    while len(full) > MAX_PROMPT_CHARS and ctx_lines:
        ctx_lines.pop(0)
        ctx = "\n\nHISTÓRICO:\n\n" + "\n\n".join(ctx_lines) if ctx_lines else "\n\nHistórico omitido para preservar o conteúdo integral dos anexos."
        full = SYSTEM_INSTRUCTIONS + ctx + att_ctx + request_ctx
    if len(full) > MAX_PROMPT_CHARS:
        raise ValueError(
            "O conteúdo integral dos anexos excede o limite de texto aceito pelo Codex. "
            "Nenhum anexo foi truncado; divida o arquivo em partes menores e tente novamente."
        )
    return full

def finish_request():
    global request_running; request_running = False
    if not root.winfo_exists(): return
    send_button.config(state="normal"); question_entry.config(state="normal"); question_entry.focus_set()

def finish_response(response, status, role="assistant"):
    if not root.winfo_exists(): return
    append_message("Assistente Linux" if role == "assistant" else "Erro", response, role)
    persist_message(role, response); set_status(status); finish_request()

# ---------- CONFIRMAÇÃO DA PERSONA ----------
def request_persona_confirmation():
    global persona_confirmed_session_id, codex_thread_id
    if not codex_path: return
    if current_session is None: return
    if persona_confirmed_session_id == current_session["id"]: return
    if not codex_authenticated(): return
    if request_running:
        root.after(2000, request_persona_confirmation); return
    persona_confirmed_session_id = current_session["id"]
    set_status("Confirmando modelo de atuação com o Codex...")

    def worker():
        global codex_thread_id
        proc = None
        try:
            fd, out_file = tempfile.mkstemp(prefix="persona-", suffix=".txt", dir=str(APP_DIR)); os.close(fd)
            prompt = (
                "Confirme e descreva brevemente, em português brasileiro, o modelo de "
                "atuação que você assume a partir da persona abaixo. Não faça perguntas; "
                "apenas confirme o perfil, resuma em 3 a 5 linhas as diretrizes principais "
                "e indique que aguarda a configuração do sistema (uname -a) para começar.\n\n"
                + SYSTEM_INSTRUCTIONS
            )
            cmd = [codex_path, "exec"] + CODEX_LANDLOCK_ARGS + ["--sandbox", "read-only",
                   "--skip-git-repo-check", "--json", "--output-last-message", out_file, "-"]
            proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, cwd=str(APP_DIR),
                                     env=os.environ.copy(), start_new_session=True)
            out_data, err_data = proc.communicate(input=prompt, timeout=180)
            out = ""
            try: out = Path(out_file).read_text(encoding="utf-8", errors="replace").strip()
            except OSError: pass
            err = (err_data or "").strip()
            if out_data:
                for line in out_data.splitlines():
                    try:
                        ev = json.loads(line)
                        tid = ev.get("thread_id") or ev.get("thread", {}).get("id")
                        if tid:
                            codex_thread_id = tid
                            break
                    except (json.JSONDecodeError, AttributeError):
                        continue
            if proc.returncode == 0 and out:
                root.after(0, lambda: finish_response(out, "Modelo de atuação confirmado.", "assistant"))
            else:
                fail_msg = ("Não foi possível confirmar o modelo de atuação automaticamente.\n\n"
                            + (err or out_data or "Sem detalhes do Codex."))
                root.after(0, lambda: finish_response(fail_msg, "Falha na confirmação inicial.", "error"))
        except subprocess.TimeoutExpired:
            if proc is not None:
                try: proc.kill()
                except Exception: pass
            root.after(0, lambda: finish_response("Tempo esgotado ao confirmar o modelo de atuação.", "Timeout na confirmação.", "error"))
        except Exception as exc:
            if proc is not None:
                try: proc.kill()
                except Exception: pass
            root.after(0, lambda: finish_response(f"Erro ao confirmar modelo de atuação:\n{exc}", "Erro na confirmação.", "error"))
        finally:
            try: os.remove(out_file)
            except (OSError, UnboundLocalError): pass

    threading.Thread(target=worker, daemon=True).start()

# ---------- EXECUÇÃO DA PERGUNTA ----------
def execute_question(question, previous_messages, attachments):
    global codex_thread_id
    output_file = None
    proc = None
    prepared_paths = []
    try:
        cleanup_temp_attachments()
        for f in attachments:
            p = prepare_attachment_for_codex(f)
            if p:
                prepared_paths.append(p)

        fd, output_file = tempfile.mkstemp(prefix="assistente-", suffix=".txt", dir=str(APP_DIR)); os.close(fd)
        # Lê os arquivos originais no processo Python antes de chamar o Codex.
        # Assim, a leitura não depende das permissões do sandbox para executar cat.
        prompt = build_prompt(question, previous_messages, attachments)

        if codex_thread_id:
            cmd = [codex_path, "exec", "resume", codex_thread_id] + CODEX_LANDLOCK_ARGS + [
                   "--skip-git-repo-check", "--json", "-c", 'sandbox_mode="read-only"',
                   "--output-last-message", output_file]
        else:
            cmd = [codex_path, "exec"] + CODEX_LANDLOCK_ARGS + [
                   "--sandbox", "read-only", "--json",
                   "--skip-git-repo-check",
                   "--output-last-message", output_file]

        for f in attachments:
            if Path(f).suffix.lower() in ('.png', '.jpg', '.jpeg', '.gif', '.webp'):
                cmd.extend(["--image", f])
        cmd.append("-")

        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, cwd=str(APP_DIR),
                                 env=os.environ.copy(), start_new_session=True)
        out_data, err_data = proc.communicate(input=prompt, timeout=300)
        out = ""
        try: out = Path(output_file).read_text(encoding="utf-8", errors="replace").strip()
        except OSError: pass
        err = (err_data or "").strip()
        if not codex_thread_id and out_data:
            for line in out_data.splitlines():
                try:
                    ev = json.loads(line)
                    tid = ev.get("thread_id") or ev.get("thread", {}).get("id")
                    if tid:
                        codex_thread_id = tid
                        break
                except (json.JSONDecodeError, AttributeError):
                    continue
        if proc.returncode == 0 and out:
            root.after(0, lambda: finish_response(out, "Resposta recebida.", "assistant"))
        elif proc.returncode == 0:
            root.after(0, lambda: finish_response("Codex sem resposta.\n\n" + (err or out_data or "Sem detalhes."), "Sem resposta.", "error"))
        else:
            root.after(0, lambda: finish_response(f"Falha no Codex ({proc.returncode}).\n\n" + (err or out or "Sem detalhes."), "Falha.", "error"))
    except subprocess.TimeoutExpired:
        if proc is not None:
            try: proc.kill()
            except Exception: pass
        root.after(0, lambda: finish_response("Timeout de 300s.", "Timeout.", "error"))
    except Exception as exc:
        if proc is not None:
            try: proc.kill()
            except Exception: pass
        root.after(0, lambda: finish_response(f"Erro: {exc}", "Erro.", "error"))
    finally:
        if output_file:
            try: os.remove(output_file)
            except OSError: pass
        for p in prepared_paths:
            try: os.remove(p)
            except OSError: pass

def send_question(event=None):
    global request_running
    if request_running: return "break"
    question = question_entry.get("1.0", "end-1c").strip()
    if not question: return "break"

    # Pedidos de reprodução integral são atendidos localmente. Isso evita que o
    # Codex responda que o anexo já está no contexto ou se recuse a repeti-lo.
    # A leitura funciona mesmo sem autenticação do Codex e não executa cat.
    if attached_files and is_direct_attachment_display_request(question):
        if current_session is None:
            create_session()
        file_list = list(attached_files)
        append_message("Você", question, "user")
        append_message("Anexos", "\n".join(f"- {Path(f).name}" for f in file_list), "user")
        persist_message("user", question)
        response = render_attached_file_contents(file_list)
        append_message("Assistente Linux", response, "assistant")
        persist_message("assistant", response)
        question_entry.delete("1.0", "end")
        clear_attachments()
        set_status("Conteúdo integral do(s) arquivo(s) exibido localmente.")
        return "break"

    if not codex_authenticated():
        send_button.config(state="disabled"); question_entry.config(state="disabled"); open_login_terminal(); return "break"
    if current_session is None: create_session()
    prev = list(current_session.get("messages", []))
    request_running = True
    question_entry.delete("1.0", "end"); question_entry.config(state="disabled"); send_button.config(state="disabled")
    append_message("Você", question, "user")
    if attached_files: append_message("Anexos", "\n".join(f"- {Path(f).name}" for f in attached_files), "user")
    persist_message("user", question)
    set_status("Consultando o Codex...")
    threading.Thread(target=execute_question, args=(question, prev, attached_files.copy()), daemon=True).start()
    clear_attachments(); return "break"

def on_enter(event):
    if event.state & 0x0001: return
    send_question(); return "break"

def handle_new_chat():
    if request_running: set_status("Aguarde."); return
    create_session(); set_status("Nova conversa.")

def handle_close():
    if request_running:
        if not messagebox.askyesno(APP_TITLE, "Consulta em andamento. Fechar?"): return
    root.destroy()

def handle_reconfirm_persona():
    global persona_confirmed_session_id, codex_thread_id
    if request_running: set_status("Aguarde."); return
    persona_confirmed_session_id = None
    codex_thread_id = None
    request_persona_confirmation()

# ---------- INTERFACE ----------
root = tk.Tk(); root.title(APP_TITLE); root.geometry("1150x680"); root.minsize(850, 520)

main_container = tk.Frame(root)
main_container.pack(fill="both", expand=True)
main_container.grid_columnconfigure(0, weight=0, minsize=280)
main_container.grid_columnconfigure(1, weight=1)
main_container.grid_rowconfigure(0, weight=1)

sidebar_frame = tk.Frame(main_container, bg="#f0f0f0", bd=1, relief="solid")
sidebar_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 4))
sidebar_frame.grid_rowconfigure(2, weight=1)
sidebar_frame.grid_columnconfigure(0, weight=1)

tk.Label(sidebar_frame, text="Conversas", font=("Sans", 11, "bold"), bg="#f0f0f0", anchor="w", padx=8, pady=6).grid(row=0, column=0, sticky="ew")

search_row = tk.Frame(sidebar_frame, bg="#f0f0f0")
search_row.grid(row=1, column=0, sticky="ew", padx=6, pady=(0, 4))
search_var = tk.StringVar()
search_var.trace_add("write", on_search_change)
search_entry = tk.Entry(search_row, textvariable=search_var, font=("Sans", 9))
search_entry.pack(side="left", fill="x", expand=True, padx=(0, 4))
search_btn = tk.Button(search_row, text="Pesquisar", command=apply_search, font=("Sans", 8, "bold"), padx=6, pady=2)
search_btn.pack(side="left", padx=(0, 2))
clear_search_btn = tk.Button(search_row, text="✖", command=clear_search, font=("Sans", 8), fg="red", padx=4, pady=2)
clear_search_btn.pack(side="left")

list_wrap = tk.Frame(sidebar_frame, bg="#f0f0f0")
list_wrap.grid(row=2, column=0, sticky="nsew", padx=6, pady=(0, 4))
list_wrap.grid_rowconfigure(0, weight=1)
list_wrap.grid_columnconfigure(0, weight=1)

sidebar_scrollbar = tk.Scrollbar(list_wrap, orient="vertical")
sidebar_scrollbar.grid(row=0, column=1, sticky="ns")

sidebar_listbox = tk.Listbox(list_wrap, yscrollcommand=sidebar_scrollbar.set, font=("Sans", 9, "bold"),
                             selectmode=tk.SINGLE, exportselection=False, activestyle="none",
                             width=32, height=20, bd=0, highlightthickness=0)
sidebar_listbox.grid(row=0, column=0, sticky="nsew")
sidebar_scrollbar.config(command=sidebar_listbox.yview)
sidebar_listbox.bind("<<ListboxSelect>>", on_sidebar_click)
sidebar_listbox.bind("<Double-Button-1>", on_sidebar_double_click)

btn_row_1 = tk.Frame(sidebar_frame, bg="#f0f0f0")
btn_row_1.grid(row=3, column=0, sticky="ew", padx=6, pady=(0, 2))
tk.Button(btn_row_1, text="Abrir", command=open_selected_session,
          font=("Sans", 9), anchor="center", padx=6, pady=4).pack(side="left", fill="x", expand=True, padx=(0, 2))
tk.Button(btn_row_1, text="+ Nova Conversa", command=handle_new_chat,
          font=("Sans", 9), anchor="center", padx=6, pady=4).pack(side="left", fill="x", expand=True, padx=(2, 0))

btn_row_2 = tk.Frame(sidebar_frame, bg="#f0f0f0")
btn_row_2.grid(row=4, column=0, sticky="ew", padx=6, pady=(0, 8))
tk.Button(btn_row_2, text="🗑 Deletar conversa selecionada", command=delete_selected_session,
          font=("Sans", 9, "bold"), fg="#a83232", anchor="center", padx=6, pady=4).pack(fill="x")

main_frame = tk.Frame(main_container, padx=8, pady=8)
main_frame.grid(row=0, column=1, sticky="nsew")

answer_frame = tk.Frame(main_frame)
answer_frame.pack(fill="both", expand=True, pady=(0, 8))
answer_box = tk.Text(answer_frame, wrap="word", font=("Sans", 10), state="disabled", padx=10, pady=8)
answer_scrollbar = tk.Scrollbar(answer_frame, command=answer_box.yview)
answer_box.configure(yscrollcommand=answer_scrollbar.set)
answer_scrollbar.pack(side="right", fill="y")
answer_box.pack(side="left", fill="both", expand=True)

answer_box.tag_configure("banner", foreground="#2c3e50", font=("Sans", 11, "bold"), justify="center")
answer_box.tag_configure("banner_info", foreground="#555555", font=("Sans", 9), justify="center")
answer_box.tag_configure("header_user", background="#1e5aa8", foreground="#ffffff",
                         font=("Sans", 10, "bold"), spacing1=6, spacing3=6, lmargin1=6, lmargin2=6)
answer_box.tag_configure("header_assistant", background="#1e7a3c", foreground="#ffffff",
                         font=("Sans", 10, "bold"), spacing1=6, spacing3=6, lmargin1=6, lmargin2=6)
answer_box.tag_configure("header_error", background="#a83232", foreground="#ffffff",
                         font=("Sans", 10, "bold"), spacing1=6, spacing3=6, lmargin1=6, lmargin2=6)
answer_box.tag_configure("user", foreground="#1a3f66", lmargin1=10, lmargin2=10)
answer_box.tag_configure("assistant", foreground="#0d4d2c", lmargin1=10, lmargin2=10, spacing3=4)
answer_box.tag_configure("error", foreground="#7a1a1a", lmargin1=10, lmargin2=10)

attachment_row = tk.Frame(main_frame)
attachment_row.pack(fill="x", pady=(0, 4))
tk.Button(attachment_row, text="📎 Anexar", command=attach_files, font=("Sans", 9)).pack(side="left")
attachment_label = tk.Label(attachment_row, text="Nenhum arquivo anexado", font=("Sans", 8), fg="#888888", anchor="w")
attachment_label.pack(side="left", padx=(6, 0), fill="x", expand=True)
clear_attachments_btn = tk.Button(attachment_row, text="✖", command=clear_attachments, font=("Sans", 8), fg="red")

question_entry = tk.Text(main_frame, font=("Sans", 11), height=3, wrap="word")
question_entry.pack(fill="x", pady=(0, 4))
question_entry.bind("<Return>", on_enter)

send_button = tk.Button(main_frame, text="ENVIAR", width=15, command=send_question)
send_button.pack(fill="x", pady=(0, 4))

status_var = tk.StringVar(value="Inicializando...")
tk.Label(main_frame, textvariable=status_var, anchor="w", fg="#555555", font=("Sans", 8)).pack(fill="x")

menu_bar = tk.Menu(root)
conv_menu = tk.Menu(menu_bar, tearoff=0)
conv_menu.add_command(label="Nova conversa", command=handle_new_chat)
conv_menu.add_command(label="Abrir conversa selecionada", command=open_selected_session)
conv_menu.add_command(label="Deletar conversa selecionada", command=delete_selected_session)
conv_menu.add_separator()
conv_menu.add_command(label="Reconfirmar modelo de atuação", command=handle_reconfirm_persona)
conv_menu.add_command(label="Atualizar lista lateral", command=update_sidebar_history)
menu_bar.add_cascade(label="Conversas", menu=conv_menu)
root.config(menu=menu_bar)
root.bind("<Control-n>", lambda e: handle_new_chat())

# ---------- INICIALIZAÇÃO ----------
codex_path = locate_codex()
create_session(clear=True)
update_sidebar_history()

if not codex_path:
    send_button.config(state="disabled"); question_entry.config(state="disabled")
    set_status("Erro: Codex não encontrado.")
    messagebox.showerror(APP_TITLE, "Codex CLI não localizado. Execute o instalador novamente.")
else:
    try: CODEX_FILE.write_text(codex_path + "\n", encoding="utf-8")
    except OSError: pass
    if codex_authenticated():
        set_status("Codex autenticado. Pronto.")
        question_entry.focus_set()
        root.after(300, request_persona_confirmation)
    else:
        send_button.config(state="disabled"); question_entry.config(state="disabled")
        root.after(500, open_login_terminal)

root.mainloop()
PYTHON

chmod 644 "$APP_FILE"
log "OK" "[4/8] Aplicativo Python gravado."
progress_done 3

# ============================================================
# FASE 4
# ============================================================
progress_begin 4 "Fase 5/8 — Criação do script de autenticação"

log "INFO" "[5/8] Gravando login-codex.sh..."
cat > "$LOGIN_SCRIPT" <<'LOGIN'
#!/bin/bash
APP_DIR="$HOME/LinuxSupportAgent"
CODEX_BIN="$(cat "$APP_DIR/codex-path.txt" 2>/dev/null || true)"
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then echo "[ERRO] Codex não encontrado."; else
    echo "============================================================"
    echo " AUTENTICAÇÃO DO CODEX"
    echo "============================================================"
    echo "Siga as instruções para entrar com sua conta ChatGPT."
    echo
    "$CODEX_BIN" login
    RESULT=$?
    echo
    if [ "$RESULT" -eq 0 ]; then echo "Login concluído."; else echo "Login falhou. Código: $RESULT"; fi
fi
echo; read -r -p "Pressione ENTER para fechar..."
LOGIN
chmod 755 "$LOGIN_SCRIPT"
log "OK" "[5/8] Script de autenticação criado."
progress_done 4

# ============================================================
# FASE 5
# ============================================================
progress_begin 5 "Fase 6/8 — Validação do código Python"

log "INFO" "[6/8] Executando py_compile..."
if ! python3 -m py_compile "$APP_FILE"; then
    log "ERROR" "Erro de sintaxe no Python."
    exit 1
fi
rm -rf "$APP_DIR/__pycache__"
log "OK" "[6/8] Sintaxe OK."
progress_done 5

# ============================================================
# FASE 6
# ============================================================
progress_begin 6 "Fase 7/8 — Criação de atalhos"

log "INFO" "[7/8] Criando launcher..."
cat > "$LAUNCHER" <<'LAUNCHER'
#!/bin/bash
APP_DIR="$HOME/LinuxSupportAgent"
export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
exec python3 "$APP_DIR/linux_support_agent.py"
LAUNCHER
chmod 755 "$LAUNCHER"

log "INFO" "[7/8] Detectando pasta Desktop..."
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then
    for C in "$HOME/Área de trabalho" "$HOME/Desktop" "$HOME/Escritorio"; do if [ -d "$C" ]; then DESKTOP_DIR="$C"; break; fi; done
fi
if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then mkdir -p "$HOME/Desktop"; DESKTOP_DIR="$HOME/Desktop"; fi

APP_ICON="utilities-terminal"
if [ -f "$APP_DIR/assistente-linux.svg" ]; then APP_ICON="$APP_DIR/assistente-linux.svg"; fi

log "INFO" "[7/8] Escrevendo .desktop em $DESKTOP_DIR..."
create_desktop_entry() {
    local TARGET="$1"
    cat > "$TARGET" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=Assistente Linux
Comment=Assistente de suporte técnico Linux
Exec="$LAUNCHER"
Path=$APP_DIR
Icon=$APP_ICON
Terminal=false
Categories=Utility;
StartupNotify=true
DESKTOP
    chmod 755 "$TARGET"
    if command -v gio >/dev/null 2>&1; then gio set "$TARGET" metadata::trusted true 2>/dev/null || true; fi
}
create_desktop_entry "$DESKTOP_DIR/Assistente Linux.desktop"
create_desktop_entry "$HOME/.local/share/applications/assistente-linux.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true; fi
log "OK" "[7/8] Atalhos criados."
progress_done 6

# ============================================================
# FASE 7
# ============================================================
progress_begin 7 "Fase 8/8 — Verificação final do Codex"

log "INFO" "[8/8] Verificando versão do Codex..."
log "OK" "[8/8] Versão do Codex: $("$CODEX_BIN" --version 2>&1 | head -n1)"

progress_done 7
# Estado final explícito: ambas as barras ficam em 100% até encerrar.
PROGRESS_CURRENT="$PROGRESS_TOTAL"
PHASE_PERCENT=100
PHASE_NUMBER="$PROGRESS_TOTAL"
PROGRESS_DESC="Instalação concluída — 100%"
draw_bar

[ "$IS_TTY" -eq 1 ] && printf "\n" >&2

log "OK" "════════════════════════════════════════════════════════════"
log "OK" " INSTALAÇÃO CONCLUÍDA (v34)"
log "OK" "════════════════════════════════════════════════════════════"
log "INFO" "Aplicativo: $APP_FILE"
log "INFO" "Log:        ${LOG_FILE:-<desabilitado>}"
log "INFO" "Backup:     $BACKUP_DIR"
log "INFO" "Ícone:      $APP_ICON"
log "OK" "════════════════════════════════════════════════════════════"
