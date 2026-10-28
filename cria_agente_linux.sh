#!/bin/bash
# ============================================================
# Assistente Linux - Instalador e configurador
# Versão 7 (final): rotação de histórico, destaque da conversa
# ativa na sidebar, botão de reconfirmação da persona, ícone SVG
# e kill de subprocesso em timeout.
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

mkdir -p "$APP_DIR" "$HISTORY_DIR" "$BACKUP_DIR"
chmod 700 "$HISTORY_DIR" 2>/dev/null || true

# --- Log sem exigir root ---
LOG_DIR=""; LOG_FILE=""
if [ -w /var/log ]; then
    LOG_DIR="/var/log"; LOG_FILE="${LOG_DIR}/assistente-linux-install.log"
elif sudo -n true 2>/dev/null; then
    LOG_DIR="/var/log"; LOG_FILE="${LOG_DIR}/assistente-linux-install.log"
    if sudo -n touch "$LOG_FILE" 2>/dev/null && sudo -n chown "$(id -un):$(id -gn)" "$LOG_FILE" 2>/dev/null; then :; else
        LOG_DIR="$APP_DIR/logs"; LOG_FILE="${LOG_DIR}/assistente-linux-install.log"; fi
else
    LOG_DIR="$APP_DIR/logs"; LOG_FILE="${LOG_DIR}/assistente-linux-install.log"
fi
mkdir -p "$LOG_DIR" 2>/dev/null || true
if ! touch "$LOG_FILE" 2>/dev/null; then LOG_FILE="/dev/null"; fi

log() {
    local level="$1"; shift
    local msg="$*"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    if [ "$LOG_FILE" = "/dev/null" ]; then echo "$line" >&2; else echo "$line" | tee -a "$LOG_FILE" >&2; fi
}
if [ "$LOG_FILE" != "/dev/null" ]; then exec > >(tee -a "$LOG_FILE") 2>&1; fi

log "INFO" "Iniciando instalação do Assistente Linux (v7 final)"

if [ "$(id -u)" -eq 0 ]; then log "ERROR" "Execute como usuário normal."; exit 1; fi
if [ ! -f /etc/os-release ]; then log "ERROR" "Distribuição não identificada."; exit 1; fi
. /etc/os-release
if ! command -v sudo >/dev/null 2>&1; then log "ERROR" "sudo é necessário."; exit 1; fi

if [ -f "$APP_FILE" ]; then cp -a "$APP_FILE" "${APP_FILE}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true; fi
if [ -d "$APP_DIR" ]; then tar -czf "$BACKUP_DIR/app_backup.tar.gz" -C "$HOME" "LinuxSupportAgent" 2>/dev/null || true; fi

echo "============================================================"
echo " INSTALADOR - ASSISTENTE LINUX v7 (final)"
echo "============================================================"
echo "Distribuição: ${PRETTY_NAME:-Linux}"
echo "Log:          $LOG_FILE"
echo "Backup:       $BACKUP_DIR"
echo

install_dependencies() {
    log "INFO" "[1/7] Instalando dependências..."
    local deps_apt="python3 python3-tk curl ca-certificates xdg-utils xdg-user-dirs xterm desktop-file-utils"
    local deps_dnf="python3 python3-tkinter curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_pacman="python tk curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_zypper="python3 python3-tkinter curl ca-certificates xdg-utils xterm desktop-file-utils"
    local deps_apk="python3 py3-tkinter curl ca-certificates xdg-utils xterm"

    if command -v apt-get >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $deps_apt
    elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y $deps_dnf
    elif command -v yum >/dev/null 2>&1; then sudo yum install -y $deps_dnf
    elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --needed --noconfirm $deps_pacman
    elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive install $deps_zypper
    elif command -v apk >/dev/null 2>&1; then sudo apk add $deps_apk
    else log "ERROR" "Gerenciador não reconhecido."; exit 1; fi
    log "INFO" "Dependências instaladas."
}
install_dependencies
mkdir -p "$HOME/.local/share/applications"

# --- Codex ---
log "INFO" "[2/7] Localizando Codex CLI..."
CODEX_BIN=""
if [ -f "$CODEX_FILE" ]; then SAVED_CODEX="$(cat "$CODEX_FILE" 2>/dev/null || true)"; if [ -n "$SAVED_CODEX" ] && [ -x "$SAVED_CODEX" ]; then CODEX_BIN="$SAVED_CODEX"; fi; fi
if [ -z "$CODEX_BIN" ] && command -v codex >/dev/null 2>&1; then CODEX_BIN="$(command -v codex)"; fi
if [ -z "$CODEX_BIN" ]; then for C in "$HOME/.local/bin/codex" "$HOME/.codex/bin/codex" "$HOME/.npm-global/bin/codex" "/usr/local/bin/codex" "/usr/bin/codex"; do if [ -x "$C" ]; then CODEX_BIN="$C"; break; fi; done; fi
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    log "WARN" "Codex não encontrado. Instalando..."
    TMP="$(mktemp)"
    if curl -fsSL -o "$TMP" https://chatgpt.com/codex/install.sh && [ -s "$TMP" ]; then sh "$TMP"; else log "ERROR" "Falha ao baixar."; fi
    rm -f "$TMP"
    export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
    if command -v codex >/dev/null 2>&1; then CODEX_BIN="$(command -v codex)"; fi
fi
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then log "ERROR" "Codex não encontrado."; exit 1; fi
printf '%s\n' "$CODEX_BIN" > "$CODEX_FILE"
log "INFO" "Codex: $CODEX_BIN"

# --- Aplicativo Python ---
log "INFO" "[3/7] Criando o assistente..."

cat > "$APP_FILE" <<'PYTHON'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os, json, uuid, tempfile, subprocess, threading, re
from pathlib import Path
from datetime import datetime
from shutil import which
import tkinter as tk
from tkinter import messagebox, filedialog

APP_DIR = Path.home() / "LinuxSupportAgent"
CODEX_FILE = APP_DIR / "codex-path.txt"
LOGIN_SCRIPT = APP_DIR / "login-codex.sh"
HISTORY_DIR = APP_DIR / "historico"
APP_TITLE = "Assistente Linux"

MAX_HISTORY_SESSIONS = 50  # rotação: mantém no máximo 50 arquivos

APP_DIR.mkdir(parents=True, exist_ok=True)
HISTORY_DIR.mkdir(parents=True, exist_ok=True)
try: HISTORY_DIR.chmod(0o700)
except OSError: pass

codex_path = ""
request_running = False
login_terminal_open = False
current_session = None
attached_files = []
persona_confirmed_session_id = None
active_session_id = None  # para destacar na sidebar

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
    """Mantém no máximo MAX_HISTORY_SESSIONS arquivos .json; apaga os mais antigos."""
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

def create_session():
    global current_session, persona_confirmed_session_id, active_session_id
    current_session = {"id": str(uuid.uuid4()), "title": "Nova conversa", "created_at": now_iso(), "updated_at": now_iso(), "messages": []}
    try: save_session(current_session)
    except OSError as exc: messagebox.showerror(APP_TITLE, f"Erro ao criar histórico:\n{exc}")
    persona_confirmed_session_id = None
    active_session_id = current_session["id"]
    clear_answer_box(); update_sidebar_history(); question_entry.focus_set()
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
    answer_box.insert("end", content.rstrip() + "\n\n", tag)
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

def update_sidebar_history():
    if 'sidebar_listbox' not in globals(): return
    sidebar_listbox.delete(0, tk.END)
    sessions = list_sessions()
    for i, s in enumerate(sessions):
        t = truncate_title(s.get("title", "Conversa"), 30)
        sidebar_listbox.insert(tk.END, f"  {t}  ")
        if s.get("id") == active_session_id:
            # Conversa ativa: destaque laranja
            sidebar_listbox.itemconfig(i, background="#f0ad4e", foreground="#000000",
                                        selectbackground="#f0ad4e", selectforeground="#000000")
        else:
            bg = "#1e7a3c" if i % 2 == 0 else "#1e5aa8"
            sidebar_listbox.itemconfig(i, background=bg, foreground="#ffffff",
                                        selectbackground="#f0ad4e", selectforeground="#000000")

def on_sidebar_select(event=None):
    global current_session, active_session_id
    if request_running: set_status("Aguarde."); return
    sel = sidebar_listbox.curselection()
    if not sel: return
    sessions = list_sessions()
    if sel[0] >= len(sessions): return
    try:
        current_session = load_session(sessions[sel[0]]["id"])
        active_session_id = current_session["id"]
        display_session(current_session); update_sidebar_history()
        set_status("Conversa carregada."); question_entry.focus_set()
    except Exception as exc: messagebox.showerror(APP_TITLE, f"Erro ao abrir:\n{exc}")

# ---------- ANEXOS ----------
def attach_files():
    global attached_files
    files = filedialog.askopenfilenames(title="Anexar arquivos", filetypes=[
        ("Imagens", "*.png *.jpg *.jpeg *.gif *.webp"),
        ("Texto/Código", "*.txt *.py *.sh *.js *.html *.css *.json *.md *.log"),
        ("Todos", "*.*")])
    for f in files:
        if f not in attached_files: attached_files.append(f)
    update_attachment_display()
def update_attachment_display():
    if 'attachment_label' not in globals(): return
    if attached_files:
        attachment_label.config(text=f"Anexos: {', '.join(Path(f).name for f in attached_files)}", fg="#0066cc")
        clear_attachments_btn.pack(side="left", padx=(5, 0))
    else:
        attachment_label.config(text="Nenhum arquivo anexado", fg="#888888"); clear_attachments_btn.pack_forget()
def clear_attachments():
    global attached_files; attached_files = []; update_attachment_display()

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

# ---------- PERSONALIDADE DO AGENTE ----------
SYSTEM_INSTRUCTIONS = """Nesta missão, atue como especialista linux com foco em desenvolvimento de scripts bash e suporte a sistemas Linux antigos e atuais, para desenvolvimento de shell scripts para automação de processos e gerenciamento de ambientes.

Antes de iniciar uma solicitação, sempre perguntar qual é a configuração atual do sistema para então gerar os scripts corretamente e / ou informar o comando correto para a distro (kernel) do sistema com o uname -a em ambientes Linux.

Após informado sobre qual o sistema atual, gerar o script executando antes de tudo o reconhecimento da versão atual do sistema, o repositório correto e os pacotes correspondentes corretos para o sistema detectado, assim como instalar os pacotes e modulos ausentes quando verificado a necessidade, e após isto, realizar sempre o back- up automatico do ambiente em todo script, antes de qualquer alteração no ambiente que possa comprometer o sistema e dar tela preta.

IDIOMA: Responda em português brasileiro, objetivo e técnico.
CONTINUIDADE: Considere o histórico anterior.
FONTES: Priorize documentação oficial. Não invente links ou versões.
SCRIPTS: Entregue scripts completos em um único bloco. Explique riscos de operações destrutivas.
SEGURANÇA: Não execute comandos no sistema do usuário; permaneça em modo somente leitura."""

def build_prompt(question, previous_messages, attachments):
    ctx_lines = []
    for m in previous_messages[-16:]:
        r, c = m.get("role", ""), m.get("content", "")
        if not isinstance(c, str): continue
        if r == "user": lbl = "USUÁRIO"
        elif r == "assistant": lbl = "ASSISTENTE"
        else: continue
        ctx_lines.append(f"{lbl}:\n{c[:12000]}")
    ctx = "\n\nHISTÓRICO:\n\n" + "\n\n".join(ctx_lines) if ctx_lines else "\n\nPrimeira pergunta."
    att_ctx = ""
    if attachments:
        att_ctx = "\n\nARQUIVOS ANEXADOS:\n"
        for f in attachments:
            p = Path(f)
            if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.gif', '.webp'):
                att_ctx += f"- Imagem: {p.name}\n"
            else:
                try: att_ctx += f"- Arquivo {p.name}:\n```\n{p.read_text(encoding='utf-8', errors='replace')[:10000]}\n```\n"
                except Exception: att_ctx += f"- Arquivo (ilegível): {p.name}\n"
    return SYSTEM_INSTRUCTIONS + ctx + att_ctx + "\n\nNOVA SOLICITAÇÃO:\n" + question

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
    global persona_confirmed_session_id
    if not codex_path: return
    if current_session is None: return
    if persona_confirmed_session_id == current_session["id"]: return
    if not codex_authenticated(): return
    if request_running:
        root.after(2000, request_persona_confirmation); return
    persona_confirmed_session_id = current_session["id"]
    set_status("Confirmando modelo de atuação com o Codex...")

    def worker():
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
            cmd = [codex_path, "exec", "--sandbox", "read-only", "--ephemeral",
                   "--skip-git-repo-check", "--output-last-message", out_file, "-"]
            proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, cwd=str(APP_DIR),
                                     env=os.environ.copy(), start_new_session=True)
            out_data, err_data = proc.communicate(input=prompt, timeout=180)
            out = ""
            try: out = Path(out_file).read_text(encoding="utf-8", errors="replace").strip()
            except OSError: pass
            err = (err_data or "").strip()
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

def execute_question(question, previous_messages, attachments):
    output_file = None
    proc = None
    try:
        fd, output_file = tempfile.mkstemp(prefix="assistente-", suffix=".txt", dir=str(APP_DIR)); os.close(fd)
        prompt = build_prompt(question, previous_messages, attachments)
        cmd = [codex_path, "exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--output-last-message", output_file]
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

def send_question(event=None):
    global request_running
    if request_running: return "break"
    question = question_entry.get("1.0", "end-1c").strip()
    if not question: return "break"
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
    """Reenvia a persona ao Codex na conversa atual, mesmo já confirmada."""
    global persona_confirmed_session_id
    if request_running: set_status("Aguarde."); return
    persona_confirmed_session_id = None
    request_persona_confirmation()

# ---------- INTERFACE ----------
root = tk.Tk(); root.title(APP_TITLE); root.geometry("1100x680"); root.minsize(820, 520)

main_container = tk.Frame(root)
main_container.pack(fill="both", expand=True)
main_container.grid_columnconfigure(0, weight=0, minsize=240)
main_container.grid_columnconfigure(1, weight=1)
main_container.grid_rowconfigure(0, weight=1)

# Sidebar
sidebar_frame = tk.Frame(main_container, bg="#f0f0f0", bd=1, relief="solid")
sidebar_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 4))
sidebar_frame.grid_rowconfigure(1, weight=1)
sidebar_frame.grid_columnconfigure(0, weight=1)

tk.Label(sidebar_frame, text="Conversas", font=("Sans", 11, "bold"), bg="#f0f0f0", anchor="w", padx=8, pady=6).grid(row=0, column=0, sticky="ew")

list_wrap = tk.Frame(sidebar_frame, bg="#f0f0f0")
list_wrap.grid(row=1, column=0, sticky="nsew", padx=6, pady=(0, 6))
list_wrap.grid_rowconfigure(0, weight=1)
list_wrap.grid_columnconfigure(0, weight=1)

sidebar_scrollbar = tk.Scrollbar(list_wrap, orient="vertical")
sidebar_scrollbar.grid(row=0, column=1, sticky="ns")

sidebar_listbox = tk.Listbox(list_wrap, yscrollcommand=sidebar_scrollbar.set, font=("Sans", 9, "bold"),
                             selectmode=tk.SINGLE, exportselection=False, activestyle="none",
                             width=28, height=20, bd=0, highlightthickness=0)
sidebar_listbox.grid(row=0, column=0, sticky="nsew")
sidebar_scrollbar.config(command=sidebar_listbox.yview)
sidebar_listbox.bind("<Double-Button-1>", on_sidebar_select)
sidebar_listbox.bind("<<ListboxSelect>>", on_sidebar_select)

tk.Button(sidebar_frame, text="+ Nova Conversa", command=handle_new_chat,
          font=("Sans", 9), anchor="center", padx=6, pady=4).grid(row=2, column=0, sticky="ew", padx=6, pady=(0, 8))

# Área principal
main_frame = tk.Frame(main_container, padx=8, pady=8)
main_frame.grid(row=0, column=1, sticky="nsew")

answer_frame = tk.Frame(main_frame)
answer_frame.pack(fill="both", expand=True, pady=(0, 8))
answer_box = tk.Text(answer_frame, wrap="word", font=("Sans", 10), state="disabled", padx=10, pady=8)
answer_scrollbar = tk.Scrollbar(answer_frame, command=answer_box.yview)
answer_box.configure(yscrollcommand=answer_scrollbar.set)
answer_scrollbar.pack(side="right", fill="y")
answer_box.pack(side="left", fill="both", expand=True)

# Tags
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

# Anexos
attachment_row = tk.Frame(main_frame)
attachment_row.pack(fill="x", pady=(0, 4))
tk.Button(attachment_row, text="📎 Anexar", command=attach_files, font=("Sans", 9)).pack(side="left")
attachment_label = tk.Label(attachment_row, text="Nenhum arquivo anexado", font=("Sans", 8), fg="#888888", anchor="w")
attachment_label.pack(side="left", padx=(6, 0), fill="x", expand=True)
clear_attachments_btn = tk.Button(attachment_row, text="✖", command=clear_attachments, font=("Sans", 8), fg="red")

# Entrada
question_entry = tk.Text(main_frame, font=("Sans", 11), height=3, wrap="word")
question_entry.pack(fill="x", pady=(0, 4))
question_entry.bind("<Return>", on_enter)

send_button = tk.Button(main_frame, text="ENVIAR", width=15, command=send_question)
send_button.pack(fill="x", pady=(0, 4))

status_var = tk.StringVar(value="Inicializando...")
tk.Label(main_frame, textvariable=status_var, anchor="w", fg="#555555", font=("Sans", 8)).pack(fill="x")

# Menu
menu_bar = tk.Menu(root)
conv_menu = tk.Menu(menu_bar, tearoff=0)
conv_menu.add_command(label="Nova conversa", command=handle_new_chat)
conv_menu.add_command(label="Reconfirmar modelo de atuação", command=handle_reconfirm_persona)
conv_menu.add_command(label="Atualizar lista lateral", command=update_sidebar_history)
menu_bar.add_cascade(label="Conversas", menu=conv_menu)
root.config(menu=menu_bar)
root.bind("<Control-n>", lambda e: handle_new_chat())

# ---------- INICIALIZAÇÃO ----------
codex_path = locate_codex()
sessions = list_sessions()
if sessions:
    try:
        current_session = load_session(sessions[0]["id"]); active_session_id = current_session["id"]
        display_session(current_session)
    except Exception: create_session()
else: create_session()
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
log "INFO" "Aplicativo criado."

# --- Login ---
log "INFO" "[4/7] Criando script de autenticação..."
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

# --- Validação ---
log "INFO" "[5/7] Validando..."
if ! python3 -m py_compile "$APP_FILE"; then log "ERROR" "Erro de sintaxe no Python."; exit 1; fi
rm -rf "$APP_DIR/__pycache__"

# --- Launcher ---
cat > "$LAUNCHER" <<'LAUNCHER'
#!/bin/bash
APP_DIR="$HOME/LinuxSupportAgent"
export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
exec python3 "$APP_DIR/linux_support_agent.py"
LAUNCHER
chmod 755 "$LAUNCHER"

# --- Atalhos ---
log "INFO" "[6/7] Criando atalhos..."
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then
    for C in "$HOME/Área de trabalho" "$HOME/Desktop" "$HOME/Escritorio"; do if [ -d "$C" ]; then DESKTOP_DIR="$C"; break; fi; done
fi
if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then mkdir -p "$HOME/Desktop"; DESKTOP_DIR="$HOME/Desktop"; fi

# Detectar ícone SVG do app, se existir
APP_ICON="utilities-terminal"
if [ -f "$APP_DIR/assistente-linux.svg" ]; then
    APP_ICON="$APP_DIR/assistente-linux.svg"
fi

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

# --- Final ---
log "INFO" "[7/7] Verificando Codex..."
"$CODEX_BIN" --version

log "INFO" "============================================================"
log "INFO" " INSTALAÇÃO CONCLUÍDA (v7 final)"
log "INFO" "============================================================"
log "INFO" "Aplicativo: $APP_FILE"
log "INFO" "Log:        $LOG_FILE"
log "INFO" "Backup:     $BACKUP_DIR"
log "INFO" "Ícone:      $APP_ICON"
log "INFO" "============================================================"
