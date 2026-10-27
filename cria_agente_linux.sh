#!/bin/bash
# ============================================================
# Assistente Linux - Instalador e configurador
# Compatibilidade: distribuições Linux com ambiente gráfico
# Interface: Python 3 + Tkinter
# IA: Codex CLI autenticado pela conta ChatGPT
# ============================================================

set -Eeuo pipefail

APP_DIR="$HOME/LinuxSupportAgent"
APP_FILE="$APP_DIR/linux_support_agent.py"
LAUNCHER="$APP_DIR/iniciar.sh"
CODEX_FILE="$APP_DIR/codex-path.txt"
LOGIN_SCRIPT="$APP_DIR/login-codex.sh"
HISTORY_DIR="$APP_DIR/historico"
DESKTOP_DIR=""

if [ "$(id -u)" -eq 0 ]; then
    echo "[ERRO] Execute como usuário normal, não como root."
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "[ERRO] Não foi possível identificar a distribuição Linux."
    exit 1
fi

. /etc/os-release

if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERRO] O comando sudo é necessário para instalar dependências."
    exit 1
fi

mkdir -p "$APP_DIR" "$HISTORY_DIR"
chmod 700 "$HISTORY_DIR"

echo "============================================================"
echo " INSTALADOR - ASSISTENTE LINUX"
echo "============================================================"
echo "Distribuição: ${PRETTY_NAME:-Linux}"
echo "Arquitetura:  $(uname -m)"
echo

install_dependencies() {
    echo "[1/7] Instalando dependências do sistema..."

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y \
            python3 python3-tk curl ca-certificates \
            xdg-utils xdg-user-dirs xterm desktop-file-utils

    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y \
            python3 python3-tkinter curl ca-certificates \
            xdg-utils xterm desktop-file-utils

    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y \
            python3 python3-tkinter curl ca-certificates \
            xdg-utils xterm desktop-file-utils

    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --needed --noconfirm \
            python tk curl ca-certificates \
            xdg-utils xterm desktop-file-utils

    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install \
            python3 python3-tkinter curl ca-certificates \
            xdg-utils xterm desktop-file-utils

    elif command -v apk >/dev/null 2>&1; then
        sudo apk add \
            python3 py3-tkinter curl ca-certificates \
            xdg-utils xterm

    else
        echo "[ERRO] Gerenciador de pacotes não reconhecido."
        echo "Instale Python 3, Tkinter, curl e um terminal gráfico."
        exit 1
    fi
}

install_dependencies

mkdir -p "$HOME/.local/share/applications"

echo "[2/7] Localizando o Codex CLI..."

CODEX_BIN=""

if [ -f "$CODEX_FILE" ]; then
    SAVED_CODEX="$(cat "$CODEX_FILE" 2>/dev/null || true)"

    if [ -n "$SAVED_CODEX" ] && [ -x "$SAVED_CODEX" ]; then
        CODEX_BIN="$SAVED_CODEX"
    fi
fi

if [ -z "$CODEX_BIN" ] && command -v codex >/dev/null 2>&1; then
    CODEX_BIN="$(command -v codex)"
fi

if [ -z "$CODEX_BIN" ]; then
    for CANDIDATE in \
        "$HOME/.local/bin/codex" \
        "$HOME/.codex/bin/codex" \
        "$HOME/.npm-global/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "$CANDIDATE" ]; then
            CODEX_BIN="$CANDIDATE"
            break
        fi
    done
fi

if [ -z "$CODEX_BIN" ] &&
   [ -d "$HOME/.codex/packages/standalone/releases" ]; then

    CODEX_BIN="$(
        find "$HOME/.codex/packages/standalone/releases" \
            -type f -name codex -perm /111 2>/dev/null |
        sort -V |
        tail -n 1
    )"
fi

if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    echo "Instalando o Codex CLI oficial..."

    curl -fsSL https://chatgpt.com/codex/install.sh | sh

    export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"

    if command -v codex >/dev/null 2>&1; then
        CODEX_BIN="$(command -v codex)"
    fi
fi

if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    echo "[ERRO] Não foi possível localizar o Codex CLI."
    exit 1
fi

printf '%s\n' "$CODEX_BIN" > "$CODEX_FILE"

echo "[3/7] Criando o assistente..."

cat > "$APP_FILE" <<'PYTHON'
#!/usr/bin/env python3

import os
import json
import uuid
import tempfile
import subprocess
import threading

import tkinter as tk
from tkinter import messagebox
from pathlib import Path
from datetime import datetime
from shutil import which


APP_DIR = Path.home() / "LinuxSupportAgent"
CODEX_FILE = APP_DIR / "codex-path.txt"
LOGIN_SCRIPT = APP_DIR / "login-codex.sh"
HISTORY_DIR = APP_DIR / "historico"

APP_TITLE = "Assistente Linux"

APP_DIR.mkdir(parents=True, exist_ok=True)
HISTORY_DIR.mkdir(parents=True, exist_ok=True)

try:
    HISTORY_DIR.chmod(0o700)
except OSError:
    pass

codex_path = ""
request_running = False
login_terminal_open = False
current_session = None


# ============================================================
# HISTÓRICO PERSISTENTE
# ============================================================

def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def format_date(value):
    try:
        parsed = datetime.fromisoformat(value)
        return parsed.astimezone().strftime("%d/%m/%Y %H:%M")
    except (ValueError, TypeError):
        return "Data desconhecida"


def session_file(session_id):
    try:
        uuid.UUID(session_id)
    except (ValueError, TypeError, AttributeError):
        raise ValueError("Identificador de conversa inválido.")

    return HISTORY_DIR / f"{session_id}.json"


def save_session(session):
    if not session:
        return

    session["updated_at"] = now_iso()
    target = session_file(session["id"])

    fd, temporary = tempfile.mkstemp(
        prefix=".historico-",
        suffix=".tmp",
        dir=str(HISTORY_DIR),
    )

    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(
                session,
                stream,
                ensure_ascii=False,
                indent=2,
            )
            stream.write("\n")

        os.chmod(temporary, 0o600)
        os.replace(temporary, target)

    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def load_session(session_id):
    path = session_file(session_id)

    with path.open("r", encoding="utf-8") as stream:
        session = json.load(stream)

    if not isinstance(session, dict):
        raise ValueError("Formato de histórico inválido.")

    if session.get("id") != session_id:
        raise ValueError("Identificador do histórico não corresponde.")

    if not isinstance(session.get("messages"), list):
        raise ValueError("Lista de mensagens inválida.")

    return session


def list_sessions():
    sessions = []

    for path in HISTORY_DIR.glob("*.json"):
        try:
            with path.open("r", encoding="utf-8") as stream:
                session = json.load(stream)

            if not isinstance(session, dict):
                continue

            if not isinstance(session.get("messages"), list):
                continue

            session_id = session.get("id")

            if not isinstance(session_id, str):
                continue

            if path.name != f"{session_id}.json":
                continue

            sessions.append(session)

        except (OSError, ValueError, json.JSONDecodeError):
            continue

    sessions.sort(
        key=lambda item: item.get("updated_at", ""),
        reverse=True,
    )

    return sessions


def create_session():
    global current_session

    current_session = {
        "id": str(uuid.uuid4()),
        "title": "Nova conversa",
        "created_at": now_iso(),
        "updated_at": now_iso(),
        "messages": [],
    }

    try:
        save_session(current_session)
    except OSError as exc:
        messagebox.showerror(
            APP_TITLE,
            f"Não foi possível criar o histórico:\n{exc}",
        )

    clear_answer_box()
    question_entry.focus_set()


def persist_message(role, content):
    global current_session

    if current_session is None:
        create_session()

    current_session["messages"].append({
        "role": role,
        "content": content,
        "time": now_iso(),
    })

    if (
        current_session.get("title") == "Nova conversa"
        and role == "user"
    ):
        title = " ".join(content.split())
        current_session["title"] = title[:65] or "Nova conversa"

    try:
        save_session(current_session)
    except OSError as exc:
        messagebox.showerror(
            APP_TITLE,
            "Não foi possível salvar o histórico.\n\n"
            f"Detalhes: {exc}",
        )


def clear_answer_box():
    answer_box.config(state="normal")
    answer_box.delete("1.0", "end")
    answer_box.config(state="disabled")


def insert_message(label, content, tag):
    answer_box.insert("end", f"{label}\n", f"{tag}_label")
    answer_box.insert("end", content.rstrip() + "\n\n", tag)


def append_message(label, content, tag):
    answer_box.config(state="normal")
    insert_message(label, content, tag)
    answer_box.config(state="disabled")
    answer_box.see("end")


def display_session(session):
    clear_answer_box()
    answer_box.config(state="normal")

    for message in session.get("messages", []):
        role = message.get("role", "")
        content = message.get("content", "")

        if not isinstance(content, str):
            continue

        if role == "user":
            insert_message("Você", content, "user")

        elif role == "assistant":
            insert_message("Assistente Linux", content, "assistant")

        elif role == "error":
            insert_message("Erro", content, "error")

    answer_box.config(state="disabled")
    answer_box.see("end")


def open_history():
    if request_running:
        set_status("Aguarde a consulta atual terminar.")
        return

    sessions = list_sessions()

    if not sessions:
        messagebox.showinfo(
            APP_TITLE,
            "Ainda não existem conversas salvas.",
        )
        return

    window = tk.Toplevel(root)
    window.title("Histórico de conversas")
    window.geometry("440x380")
    window.minsize(340, 260)
    window.transient(root)

    frame = tk.Frame(window, padx=10, pady=10)
    frame.pack(fill="both", expand=True)

    tk.Label(
        frame,
        text="Selecione uma conversa para abrir:",
        anchor="w",
        font=("Sans", 10, "bold"),
    ).pack(fill="x", pady=(0, 8))

    list_frame = tk.Frame(frame)
    list_frame.pack(fill="both", expand=True)

    scrollbar = tk.Scrollbar(list_frame)
    scrollbar.pack(side="right", fill="y")

    history_list = tk.Listbox(
        list_frame,
        font=("Sans", 9),
        yscrollcommand=scrollbar.set,
        exportselection=False,
    )
    history_list.pack(side="left", fill="both", expand=True)
    scrollbar.config(command=history_list.yview)

    for session in sessions:
        title = " ".join(
            str(session.get("title", "Conversa")).split()
        )

        if len(title) > 50:
            title = title[:47] + "..."

        date = format_date(session.get("updated_at", ""))

        history_list.insert("end", f"{title}  |  {date}")

    def open_selected(event=None):
        global current_session

        selection = history_list.curselection()

        if not selection:
            return

        selected = sessions[selection[0]]

        try:
            current_session = load_session(selected["id"])
            display_session(current_session)
            set_status(
                "Conversa anterior carregada. "
                "Você pode continuar enviando perguntas."
            )
            window.destroy()
            question_entry.focus_set()

        except (OSError, ValueError, json.JSONDecodeError) as exc:
            messagebox.showerror(
                APP_TITLE,
                f"Não foi possível abrir a conversa:\n{exc}",
                parent=window,
            )

    history_list.bind("<Double-Button-1>", open_selected)

    button_frame = tk.Frame(frame)
    button_frame.pack(fill="x", pady=(10, 0))

    tk.Button(
        button_frame,
        text="Abrir conversa",
        command=open_selected,
    ).pack(side="right", padx=(5, 0))

    tk.Button(
        button_frame,
        text="Cancelar",
        command=window.destroy,
    ).pack(side="right")

    history_list.selection_set(0)
    history_list.activate(0)


# ============================================================
# LOCALIZAÇÃO E AUTENTICAÇÃO DO CODEX
# ============================================================

def locate_codex():
    candidates = []

    try:
        saved = CODEX_FILE.read_text(encoding="utf-8").strip()

        if saved:
            candidates.append(saved)

    except OSError:
        pass

    discovered = which("codex")

    if discovered:
        candidates.insert(0, discovered)

    candidates.extend([
        str(Path.home() / ".local/bin/codex"),
        str(Path.home() / ".codex/bin/codex"),
        str(Path.home() / ".npm-global/bin/codex"),
        "/usr/local/bin/codex",
        "/usr/bin/codex",
    ])

    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    return None


def set_status(text):
    status_var.set(text)


def codex_authenticated():
    if not codex_path:
        return False

    try:
        result = subprocess.run(
            [codex_path, "login", "status"],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
            env=os.environ.copy(),
        )

        return result.returncode == 0

    except (OSError, subprocess.TimeoutExpired):
        return False


def find_terminal():
    for name in (
        "x-terminal-emulator",
        "xfce4-terminal",
        "gnome-terminal",
        "mate-terminal",
        "konsole",
        "lxterminal",
        "xterm",
    ):
        found = which(name)

        if found:
            return name, found

    return None, None


def open_login_terminal():
    global login_terminal_open

    if login_terminal_open:
        return

    if codex_authenticated():
        login_terminal_open = False

        send_button.config(state="normal")
        question_entry.config(state="normal")

        set_status("Codex autenticado. Pronto para receber perguntas.")
        question_entry.focus_set()
        return

    terminal_name, terminal_path = find_terminal()

    if not terminal_path:
        login_terminal_open = False

        send_button.config(state="disabled")
        question_entry.config(state="disabled")

        messagebox.showerror(
            APP_TITLE,
            "Nenhum terminal gráfico foi encontrado.\n\n"
            "Instale o xterm ou outro terminal compatível "
            "com sua distribuição.",
        )
        return

    login_terminal_open = True
    set_status("Aguardando autenticação do Codex...")

    try:
        if terminal_name == "gnome-terminal":
            command = [
                terminal_path,
                "--",
                "bash",
                str(LOGIN_SCRIPT),
            ]

        elif terminal_name == "konsole":
            command = [
                terminal_path,
                "-e",
                "bash",
                str(LOGIN_SCRIPT),
            ]

        elif terminal_name in ("xfce4-terminal", "mate-terminal"):
            command = [
                terminal_path,
                "--disable-server",
                "--command",
                "bash " + subprocess.list2cmdline([str(LOGIN_SCRIPT)]),
            ]

        elif terminal_name == "lxterminal":
            command = [
                terminal_path,
                "-e",
                "bash",
                str(LOGIN_SCRIPT),
            ]

        else:
            command = [
                terminal_path,
                "-e",
                "bash",
                str(LOGIN_SCRIPT),
            ]

        subprocess.Popen(
            command,
            env=os.environ.copy(),
            start_new_session=True,
        )

    except OSError as exc:
        login_terminal_open = False

        messagebox.showerror(
            APP_TITLE,
            f"Não foi possível abrir o terminal de login:\n{exc}",
        )
        return

    check_login()


def check_login():
    global login_terminal_open

    if not root.winfo_exists():
        return

    if codex_authenticated():
        login_terminal_open = False

        send_button.config(state="normal")
        question_entry.config(state="normal")

        set_status("Codex autenticado. Pronto para receber perguntas.")
        question_entry.focus_set()
        return

    set_status(
        "Aguardando login. Conclua a autenticação no terminal."
    )

    root.after(3000, check_login)


# ============================================================
# CONSULTA COM CONTEXTO E FONTES OFICIAIS
# ============================================================

SYSTEM_INSTRUCTIONS = """
Você é um especialista sênior em Linux, administração de sistemas,
diagnóstico técnico e desenvolvimento de scripts Bash.

IDIOMA E COMUNICAÇÃO:
- Responda sempre em português brasileiro.
- Seja objetivo, técnico, claro e organizado.
- Evite saudações desnecessárias e explicações redundantes.
- Respeite rigorosamente o escopo solicitado.

CONTINUIDADE:
- Considere o histórico anterior fornecido no prompt.
- Use o contexto para responder a perguntas de acompanhamento.
- Não peça novamente informações já disponíveis, salvo se precisarem
  ser atualizadas.
- Preserve as decisões e restrições anteriormente estabelecidas.
- Se a pergunta mudar de assunto, responda ao novo assunto.

FONTES OFICIAIS:
- Priorize documentação oficial da distribuição e dos projetos envolvidos.
- Quando houver acesso à pesquisa externa, consulte fontes oficiais.
- Não invente links, citações, versões ou resultados de pesquisa.
- Não afirme que consultou uma fonte que não foi realmente consultada.
- Se não houver acesso à web, informe essa limitação.
- Diferencie fatos verificados de conhecimento geral e hipóteses.

DIAGNÓSTICO:
- Considere distribuição, versão, kernel, ambiente gráfico,
  gerenciador de pacotes e limitações de hardware.
- Quando faltarem dados essenciais, solicite as informações necessárias,
  especialmente a saída de uname -a e a identificação da distribuição.
- Não invente resultados de comandos ou testes.

SCRIPTS E COMANDOS:
- Quando solicitado, entregue o script completo em um único bloco.
- Considere compatibilidade, dependências, permissões, logs e recuperação.
- Não declare que executou ou testou algo que não executou.
- Explique riscos de operações potencialmente destrutivas.
- Avalie dependências antes de recomendar remoções de pacotes.

SEGURANÇA:
- Este aplicativo é um assistente de perguntas e respostas.
- Não execute comandos de manutenção no sistema do usuário.
- Mantenha o Codex no modo somente leitura.
- Não afirme que instalou, removeu ou modificou algo no sistema.
- Prefira diagnósticos não destrutivos.

OBJETIVO:
Fornecer suporte técnico Linux fundamentado, compatível com o sistema
e com continuidade entre as mensagens da mesma conversa.
""".strip()


def build_prompt(question, previous_messages):
    context_lines = []

    for message in previous_messages[-16:]:
        role = message.get("role", "")
        content = message.get("content", "")

        if not isinstance(content, str):
            continue

        if role == "user":
            label = "USUÁRIO"
        elif role == "assistant":
            label = "ASSISTENTE"
        else:
            continue

        context_lines.append(
            f"{label}:\n{content[:12000]}"
        )

    if context_lines:
        context = (
            "\n\nHISTÓRICO ANTERIOR DA CONVERSA:\n\n"
            + "\n\n".join(context_lines)
        )
    else:
        context = "\n\nEsta é a primeira pergunta desta conversa."

    return (
        SYSTEM_INSTRUCTIONS
        + context
        + "\n\nNOVA SOLICITAÇÃO DO USUÁRIO:\n"
        + question
        + "\n\nResponda considerando o contexto anterior e as instruções."
    )


def finish_request():
    global request_running

    request_running = False

    if not root.winfo_exists():
        return

    send_button.config(state="normal")
    question_entry.config(state="normal")
    question_entry.focus_set()


def finish_response(response, status, role="assistant"):
    if not root.winfo_exists():
        return

    if role == "assistant":
        append_message("Assistente Linux", response, "assistant")
    else:
        append_message("Erro", response, "error")

    persist_message(role, response)
    set_status(status)
    finish_request()


def execute_question(question, previous_messages):
    output_file = None

    try:
        fd, output_file = tempfile.mkstemp(
            prefix="assistente-linux-",
            suffix=".txt",
            dir=str(APP_DIR),
        )
        os.close(fd)

        prompt = build_prompt(question, previous_messages)

        command = [
            codex_path,
            "exec",
            "--sandbox", "read-only",
            "--ephemeral",
            "--skip-git-repo-check",
            "--output-last-message", output_file,
            "-",
        ]

        result = subprocess.run(
            command,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
            cwd=str(APP_DIR),
            env=os.environ.copy(),
        )

        output = ""

        try:
            output = Path(output_file).read_text(
                encoding="utf-8",
                errors="replace",
            ).strip()
        except OSError:
            pass

        error = (result.stderr or "").strip()

        if result.returncode == 0 and output:
            response = output
            status = "Resposta recebida."

            root.after(
                0,
                lambda response=response, status=status:
                    finish_response(response, status, "assistant"),
            )

        elif result.returncode == 0:
            response = (
                "O Codex terminou sem produzir uma resposta.\n\n"
                + (error or result.stdout or "Nenhum detalhe informado.")
            )

            root.after(
                0,
                lambda response=response:
                    finish_response(
                        response,
                        "Nenhuma resposta recebida.",
                        "error",
                    ),
            )

        else:
            response = (
                f"Falha na consulta ao Codex. Código: {result.returncode}\n\n"
                + (error or output or "O Codex não informou detalhes.")
            )

            root.after(
                0,
                lambda response=response:
                    finish_response(
                        response,
                        "Falha ao consultar o Codex.",
                        "error",
                    ),
            )

    except subprocess.TimeoutExpired:
        response = (
            "A consulta excedeu o limite de 300 segundos. "
            "Verifique a conexão e tente novamente."
        )

        root.after(
            0,
            lambda response=response:
                finish_response(
                    response,
                    "Tempo limite excedido.",
                    "error",
                ),
        )

    except Exception as exc:
        response = f"Falha ao executar o Codex:\n{exc}"

        root.after(
            0,
            lambda response=response:
                finish_response(
                    response,
                    "Erro ao processar a pergunta.",
                    "error",
                ),
        )

    finally:
        if output_file:
            try:
                os.remove(output_file)
            except OSError:
                pass


def send_question(event=None):
    global request_running

    if request_running:
        return "break"

    question = question_entry.get().strip()

    if not question:
        return "break"

    if not codex_authenticated():
        send_button.config(state="disabled")
        question_entry.config(state="disabled")
        open_login_terminal()
        return "break"

    if current_session is None:
        create_session()

    previous_messages = list(current_session.get("messages", []))

    request_running = True

    question_entry.delete(0, "end")
    question_entry.config(state="disabled")
    send_button.config(state="disabled")

    append_message("Você", question, "user")
    persist_message("user", question)

    set_status("Consultando o Codex...")

    worker = threading.Thread(
        target=execute_question,
        args=(question, previous_messages),
        daemon=True,
    )
    worker.start()

    return "break"


def handle_new_chat():
    if request_running:
        set_status("Aguarde a consulta atual terminar.")
        return

    create_session()
    set_status("Nova conversa iniciada.")


def handle_close():
    if request_running:
        confirm = messagebox.askyesno(
            APP_TITLE,
            "Existe uma consulta em andamento.\n"
            "Deseja fechar o aplicativo mesmo assim?\n\n"
            "A pergunta enviada já foi salva no histórico.",
        )

        if not confirm:
            return

    root.destroy()


# ============================================================
# INTERFACE GRÁFICA ORIGINAL
# Mantidos tamanho, estrutura e campo de envio originais.
# O histórico fica no menu, sem painel lateral.
# ============================================================

root = tk.Tk()
root.title(APP_TITLE)
root.geometry("760x540")
root.minsize(540, 400)

main_frame = tk.Frame(root, padx=12, pady=12)
main_frame.pack(fill="both", expand=True)

# Menu de histórico sem alterar a organização da janela principal.

menu_bar = tk.Menu(root)
conversation_menu = tk.Menu(menu_bar, tearoff=0)

conversation_menu.add_command(
    label="Nova conversa",
    command=handle_new_chat,
)

conversation_menu.add_command(
    label="Consultar histórico",
    command=open_history,
)

menu_bar.add_cascade(
    label="Conversas",
    menu=conversation_menu,
)

root.config(menu=menu_bar)

root.bind("<Control-n>", lambda event: handle_new_chat())
root.bind("<Control-h>", lambda event: open_history())

title_label = tk.Label(
    main_frame,
    text="Assistente Linux",
    font=("Sans", 15, "bold"),
    anchor="w",
)
title_label.pack(fill="x", pady=(0, 10))

answer_box = tk.Text(
    main_frame,
    wrap="word",
    font=("Sans", 10),
    state="disabled",
    padx=8,
    pady=8,
)

scrollbar = tk.Scrollbar(
    main_frame,
    command=answer_box.yview,
)

answer_box.configure(yscrollcommand=scrollbar.set)

scrollbar.pack(side="right", fill="y")
answer_box.pack(fill="both", expand=True, pady=(0, 10))

# Diferenciação visual das mensagens, sem alterar a estrutura.

answer_box.tag_configure(
    "user_label",
    foreground="#1769aa",
    font=("Sans", 10, "bold"),
)

answer_box.tag_configure(
    "user",
    foreground="#244d70",
)

answer_box.tag_configure(
    "assistant_label",
    foreground="#21834a",
    font=("Sans", 10, "bold"),
)

answer_box.tag_configure(
    "assistant",
    foreground="#263445",
)

answer_box.tag_configure(
    "error_label",
    foreground="#c62828",
    font=("Sans", 10, "bold"),
)

answer_box.tag_configure(
    "error",
    foreground="#a61b1b",
)

question_frame = tk.Frame(main_frame)
question_frame.pack(fill="x")

question_entry = tk.Entry(
    question_frame,
    font=("Sans", 11),
)

question_entry.pack(
    side="left",
    fill="x",
    expand=True,
    ipady=7,
    padx=(0, 8),
)

send_button = tk.Button(
    question_frame,
    text="ENVIAR",
    width=12,
    command=send_question,
)
send_button.pack(side="right")

status_var = tk.StringVar(value="Inicializando o Codex...")

status_label = tk.Label(
    main_frame,
    textvariable=status_var,
    anchor="w",
    justify="left",
    fg="#555555",
)
status_label.pack(fill="x", pady=(8, 0))

question_entry.bind("<Return>", send_question)
root.protocol("WM_DELETE_WINDOW", handle_close)


# ============================================================
# INICIALIZAÇÃO
# ============================================================

codex_path = locate_codex()

sessions = list_sessions()

if sessions:
    try:
        current_session = load_session(sessions[0]["id"])
        display_session(current_session)
    except (OSError, ValueError, json.JSONDecodeError):
        create_session()
else:
    create_session()

if not codex_path:
    send_button.config(state="disabled")
    question_entry.config(state="disabled")

    set_status("Erro: executável do Codex não encontrado.")

    messagebox.showerror(
        APP_TITLE,
        "Não foi possível localizar o Codex CLI.\n"
        "Execute novamente o instalador.",
    )

else:
    try:
        CODEX_FILE.write_text(
            codex_path + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass

    if codex_authenticated():
        set_status("Codex autenticado. Pronto para receber perguntas.")
        question_entry.focus_set()
    else:
        send_button.config(state="disabled")
        question_entry.config(state="disabled")
        root.after(500, open_login_terminal)

root.mainloop()
PYTHON

chmod 755 "$APP_FILE"

echo "[4/7] Criando o script de autenticação..."

cat > "$LOGIN_SCRIPT" <<'LOGIN'
#!/bin/bash

APP_DIR="$HOME/LinuxSupportAgent"
CODEX_FILE="$APP_DIR/codex-path.txt"

CODEX_BIN="$(cat "$CODEX_FILE" 2>/dev/null || true)"

if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
    echo "[ERRO] Executável do Codex não encontrado."
else
    echo "============================================================"
    echo " AUTENTICAÇÃO DO CODEX"
    echo "============================================================"
    echo
    echo "Siga as instruções para entrar com sua conta ChatGPT."
    echo

    "$CODEX_BIN" login

    RESULT=$?

    echo

    if [ "$RESULT" -eq 0 ]; then
        echo "O comando de login terminou com sucesso."
    else
        echo "O login não foi concluído. Código: $RESULT"
    fi
fi

echo
read -r -p "Pressione ENTER para fechar esta janela..."
LOGIN

chmod 755 "$LOGIN_SCRIPT"

echo "[5/7] Validando os arquivos..."

if ! python3 -m py_compile "$APP_FILE"; then
    echo "[ERRO] O aplicativo Python contém erros de sintaxe."
    exit 1
fi

cat > "$LAUNCHER" <<'LAUNCHER'
#!/bin/bash

APP_DIR="$HOME/LinuxSupportAgent"

export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"

exec python3 "$APP_DIR/linux_support_agent.py"
LAUNCHER

chmod 755 "$LAUNCHER"

echo "[6/7] Criando os atalhos..."

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"

if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then
    for CANDIDATE in \
        "$HOME/Área de trabalho" \
        "$HOME/Desktop" \
        "$HOME/Escritorio"
    do
        if [ -d "$CANDIDATE" ]; then
            DESKTOP_DIR="$CANDIDATE"
            break
        fi
    done
fi

if [ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ]; then
    mkdir -p "$HOME/Desktop"
    DESKTOP_DIR="$HOME/Desktop"
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
Icon=utilities-terminal
Terminal=false
Categories=Utility;
StartupNotify=true
DESKTOP

    chmod 755 "$TARGET"

    if command -v gio >/dev/null 2>&1; then
        gio set "$TARGET" metadata::trusted true 2>/dev/null || true
    fi
}

create_desktop_entry "$DESKTOP_DIR/Assistente Linux.desktop"

create_desktop_entry \
    "$HOME/.local/share/applications/assistente-linux.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database \
        "$HOME/.local/share/applications" 2>/dev/null || true
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$DESKTOP_DIR/Assistente Linux.desktop" || true
fi

echo "[7/7] Verificando o Codex..."

"$CODEX_BIN" --version

echo
echo "============================================================"
echo " INSTALAÇÃO CONCLUÍDA"
echo "============================================================"
echo
echo "Aplicativo: $APP_FILE"
echo "Iniciador:  $LAUNCHER"
echo "Codex CLI:  $CODEX_BIN"
echo "Atalho:     $DESKTOP_DIR/Assistente Linux.desktop"
echo "Histórico:  $HISTORY_DIR"
echo
echo "Abra o ícone Assistente Linux."
echo "Se necessário, o terminal de autenticação será aberto."
echo "Use o menu Conversas para iniciar ou consultar conversas."
echo "O histórico fica salvo localmente no diretório do aplicativo."
echo "============================================================"
