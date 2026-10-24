#!/usr/bin/env bash
umask 077
PROGRAM_NAME="GitHub Manager"
API_URL="https://api.github.com"
API_VERSION="2022-11-28"
GITHUB_USER=""
GITHUB_TOKEN=""
SSH_KEY=""
TMP_DIR="${TMPDIR:-/tmp}/github-manager-$$"
mkdir -p "$TMP_DIR" || exit 1
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM
pause() {
  printf '\nPressione ENTER para continuar...'
  IFS= read -r _
}
show_banner() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
    clear 2>/dev/null || :
  fi
  printf '%s\n' \
    '╔══════════════════════════════════════════════════════════════════════╗' \
    '║                                                                      ║' \
    '║     ██████╗ ██╗████████╗██╗  ██╗██╗   ██╗██████╗                    ║' \
    '║    ██╔════╝ ██║╚══██╔══╝██║  ██║██║   ██║██╔══██╗                   ║' \
    '║    ██║  ███╗██║   ██║   ███████║██║   ██║██████╔╝                   ║' \
    '║    ██║   ██║██║   ██║   ██╔══██║██║   ██║██╔══██╗                   ║' \
    '║    ╚██████╔╝██║   ██║   ██║  ██║╚██████╔╝██████╔╝                   ║' \
    '║     ╚═════╝ ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝                    ║' \
    '║                                                                      ║' \
    '║                    GITHUB MANAGER  |  VERSÃO FINAL                   ║' \
    '║              Controle de repositórios direto pelo terminal           ║' \
    '╠══════════════════════════════════════════════════════════════════════╣' \
    '║  • Repositórios: listar, criar, renomear e excluir.                  ║' \
    '║  • Branches: criar, renomear e excluir branches secundárias.        ║' \
    '║  • Pastas: criar/excluir na MAIN e criar/renomear/excluir em branch.║' \
    '║  • Arquivos: pesquisar, baixar, enviar e excluir arquivos remotos.  ║' \
    '║  • Ambiente local: listar arquivos, trocar diretório e clonar repo.║' \
    '║  • Acesso: autenticar no GitHub e carregar chave SSH opcional.       ║' \
    '║                                                                      ║' \
    '║       Segurança: token solicitado durante a execução; não exibido.  ║' \
    '╚══════════════════════════════════════════════════════════════════════╝' \
    ''
}
valid_name() {
  case "$1" in
    ""|*[!a-zA-Z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
urlencode() {
  jq -nr --arg value "$1" '$value|@uri'
}
api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local output="${4:-$TMP_DIR/response.json}"
  local status
  if [ -n "$data" ]; then
    status=$(curl -sS -o "$output" -w '%{http_code}' \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H "Content-Type: application/json" \
      "$API_URL$endpoint" -d "$data")
  else
    status=$(curl -sS -o "$output" -w '%{http_code}' \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL$endpoint")
  fi
  case "$status" in
    200|201|202|204) return 0 ;;
    *)
      printf '\nErro na API do GitHub (HTTP %s).\n' "$status"
      if [ -s "$output" ]; then
        jq -r '.message // .' "$output" 2>/dev/null
      fi
      return 1
      ;;
  esac
}
ensure_login() {
  if [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_TOKEN" ]; then
    printf '\nFaça login no GitHub primeiro.\n'
    return 1
  fi
  return 0
}
login_github() {
  local login token key response
  printf '\nLOGIN DO GITHUB: '
  IFS= read -r login
  if [ -z "$login" ]; then
    printf 'Login inválido.\n'
    return 1
  fi
  printf 'PERSONAL ACCESS TOKEN (PAT): '
  IFS= read -r -s token
  printf '\n'
  if [ -z "$token" ]; then
    printf 'Token não informado.\n'
    return 1
  fi
  GITHUB_USER="$login"
  GITHUB_TOKEN="$token"
  if ! api GET "/user" "" "$TMP_DIR/user.json"; then
    GITHUB_USER=""
    GITHUB_TOKEN=""
    return 1
  fi
  response=$(jq -r '.login // empty' "$TMP_DIR/user.json")
  if [ -z "$response" ]; then
    printf 'Não foi possível validar o usuário.\n'
    GITHUB_USER=""
    GITHUB_TOKEN=""
    return 1
  fi
  GITHUB_USER="$response"
  printf '\nLogin confirmado: %s\n' "$GITHUB_USER"
  printf '\nCaminho da chave SSH privada (ENTER para ignorar): '
  IFS= read -r key
  if [ -n "$key" ]; then
    if [ -f "$key" ]; then
      SSH_KEY="$key"
      if command -v ssh-add >/dev/null 2>&1; then
        ssh-add "$SSH_KEY" 2>/dev/null ||
          printf 'Aviso: não foi possível adicionar a chave ao ssh-agent.\n'
      fi
    else
      printf 'Arquivo de chave SSH não encontrado. Chave não configurada.\n'
    fi
  fi
  return 0
}
logout_github() {
  GITHUB_USER=""
  GITHUB_TOKEN=""
  SSH_KEY=""
  printf '\nSessão encerrada.\n'
}
list_repositories() {
  local page count repo default_branch private path depth indent
  ensure_login || return 1
  page=1
  while :; do
    if ! api GET \
      "/user/repos?affiliation=owner&per_page=100&page=$page&sort=full_name" \
      "" "$TMP_DIR/repos.json"; then
      return 1
    fi
    count=$(jq 'length' "$TMP_DIR/repos.json" 2>/dev/null)
    [ -n "$count" ] || return 1
    [ "$count" -gt 0 ] || break
    while IFS="$(printf '\t')" read -r repo default_branch private; do
      [ -n "$repo" ] || continue
      printf '\n============================================================\n'
      printf 'REPOSITÓRIO: %s\n' "$repo"
      printf 'BRANCH PRINCIPAL: %s\n' "$default_branch"
      printf 'PRIVADO: %s\n' "$private"
      printf '%s\n' 'DIRETÓRIOS E SUBPASTAS:'
      if api GET \
        "/repos/$GITHUB_USER/$(urlencode "$repo")/git/trees/$(urlencode "$default_branch")?recursive=1" \
        "" "$TMP_DIR/tree.json"; then
        if [ "$(jq -r '.truncated // false' "$TMP_DIR/tree.json" 2>/dev/null)" = "true" ]; then
          printf '  AVISO: a API informou que a árvore foi truncada.\n'
        fi
        jq -r '.tree[]? | select(.type == "tree") | .path' \
          "$TMP_DIR/tree.json" |
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          depth=$(printf '%s\n' "$path" | awk -F '/' '{print NF-1}')
          indent="  "
          while [ "$depth" -gt 0 ]; do
            indent="${indent}  "
            depth=$((depth - 1))
          done
          printf '%s📁 %s\n' "$indent" "$path"
        done
        if ! jq -e '.tree[]? | select(.type == "tree")' \
          "$TMP_DIR/tree.json" >/dev/null 2>&1; then
          printf '  (Nenhuma pasta encontrada.)\n'
        fi
      else
        printf '  Não foi possível consultar os diretórios desta branch.\n'
      fi
    done < <(
      jq -r '.[] | [.name,.default_branch,(.private|tostring)] | @tsv' \
        "$TMP_DIR/repos.json"
    )
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
}
create_repository_main() {
  local name description visibility payload
  ensure_login || return 1
  printf '\nNome do novo repositório: '
  IFS= read -r name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Descrição (opcional): '
  IFS= read -r description
  printf 'Repositório privado? (s/n): '
  IFS= read -r visibility
  case "$visibility" in
    s|S|sim|SIM) visibility=true ;;
    *) visibility=false ;;
  esac
  payload=$(jq -n \
    --arg name "$name" \
    --arg description "$description" \
    --argjson private "$visibility" \
    '{name:$name,description:$description,private:$private,auto_init:true}')
  if api POST "/user/repos" "$payload"; then
    printf '\nRepositório criado: %s/%s\n' "$GITHUB_USER" "$name"
  fi
}
select_repository() {
  local name
  ensure_login || return 1
  printf '\nNome do repositório: '
  IFS= read -r name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  if ! api GET "/repos/$GITHUB_USER/$(urlencode "$name")" \
    "" "$TMP_DIR/repo.json"; then
    return 1
  fi
  SELECTED_REPO="$name"
  DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "$TMP_DIR/repo.json")
  return 0
}
upload_file() {
  local file remote_path encoded_repo encoded_path content sha payload http_code message
  ensure_login || return 1
  command -v base64 >/dev/null 2>&1 || {
    printf 'Erro: base64 não está disponível.\n'
    return 1
  }
  printf '\n=== ENVIAR ARQUIVO LOCAL AO GITHUB ===\n'
  printf 'Diretório local corrente: %s\n' "$PWD"
  select_repository || return 1
  printf 'Nome do arquivo local: '
  IFS= read -r file
  case "$file" in
    ""|"."|".."|*/*|*\\*)
      printf 'Erro: informe somente o nome do arquivo, sem caminhos.\n'
      return 1
      ;;
  esac
  if [ ! -f "$PWD/$file" ]; then
    printf 'Erro: arquivo não encontrado no diretório corrente: %s/%s\n' "$PWD" "$file"
    return 1
  fi
  if [ ! -r "$PWD/$file" ]; then
    printf 'Erro: o arquivo não possui permissão de leitura.\n'
    return 1
  fi
  remote_path="$file"
  encoded_repo=$(urlencode "$SELECTED_REPO") || {
    printf 'Erro ao codificar o nome do repositório.\n'
    return 1
  }
  encoded_path=$(urlencode "$file") || {
    printf 'Erro ao codificar o nome do arquivo.\n'
    return 1
  }
  content=$(base64 < "$PWD/$file" | tr -d '\r\n') || {
    printf 'Erro: não foi possível codificar o arquivo.\n'
    return 1
  }
  http_code=$(curl -sS \
    -o "$TMP_DIR/content.json" \
    -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")")
  sha=""
  case "$http_code" in
    200)
      sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
      if [ -z "$sha" ]; then
        printf 'Erro: não foi possível obter o SHA do arquivo remoto.\n'
        return 1
      fi
      ;;
    404)
      ;;
    *)
      printf 'Erro ao consultar o arquivo remoto (HTTP %s).\n' "$http_code"
      jq -r '.message // empty' "$TMP_DIR/content.json" 2>/dev/null
      return 1
      ;;
  esac
  payload=$(jq -n \
    --arg message "Envio de $remote_path via GitHub Manager" \
    --arg content "$content" \
    --arg branch "$DEFAULT_BRANCH" \
    --arg sha "$sha" \
    '{message:$message,content:$content,branch:$branch} + (if $sha != "" then {sha:$sha} else {} end)') || {
    printf 'Erro: não foi possível preparar o conteúdo do envio.\n'
    return 1
  }
  http_code=$(curl -sS \
    -o "$TMP_DIR/upload.json" \
    -w '%{http_code}' \
    -X PUT \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H "Content-Type: application/json" \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path")
  case "$http_code" in
    200|201)
      if ! jq -e '.content.sha and .commit.sha' \
        "$TMP_DIR/upload.json" >/dev/null 2>&1; then
        printf 'Erro: a API não confirmou o envio do arquivo.\n'
        jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null
        return 1
      fi
      printf '\nArquivo enviado com sucesso!\n'
      printf 'Arquivo local: %s/%s\n' "$PWD" "$file"
      printf 'Repositório remoto: %s/%s\n' "$GITHUB_USER" "$SELECTED_REPO"
      printf 'Caminho remoto: %s\n' "$remote_path"
      printf 'Branch de destino: %s\n' "$DEFAULT_BRANCH"
      printf 'Commit: %s\n' "$(jq -r '.commit.sha' "$TMP_DIR/upload.json")"
      return 0
      ;;
    409)
      message=$(jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null)
      printf 'Falha ao enviar o arquivo (HTTP 409).\n%s\n' "$message"
      case "$message" in
        *"Secret detected"*|*"secret"*|*"Secret"*)
          printf '\nO GitHub bloqueou o envio porque detectou um possível segredo no arquivo.\n'
          printf 'Remova credenciais/tokens do arquivo. Se um token real foi exposto, revogue-o e gere outro.\n'
          ;;
      esac
      return 1
      ;;
    *)
      printf 'Falha ao enviar o arquivo (HTTP %s).\n' "$http_code"
      jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null
      return 1
      ;;
  esac
}
download_file() {
  local branch path output encoded_path filename repo_encoded
  select_repository || return 1
  printf 'Branch: '
  IFS= read -r branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  IFS= read -r path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  filename="${path##*/}"
  [ -n "$filename" ] || {
    printf 'O caminho informado não contém um nome de arquivo válido.\n'
    return 1
  }
  output="$PWD/$filename"
  encoded_path=$(urlencode_path "$path") || return 1
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch")" \
    "" "$TMP_DIR/content.json"; then
    return 1
  fi
  if [ "$(jq -r '.type // empty' "$TMP_DIR/content.json")" != "file" ]; then
    printf 'O caminho informado não corresponde a um arquivo.\n'
    return 1
  fi
  if ! jq -r '.content // empty' "$TMP_DIR/content.json" |
    tr -d '\n' | base64 -d > "$output"; then
    rm -f "$output"
    printf 'Falha ao gravar o arquivo local.\n'
    return 1
  fi
  printf '\nArquivo copiado para: %s\n' "$output"
}
delete_remote_file() {
  local branch path message sha payload answer
  select_repository || return 1
  printf 'Branch: '
  IFS= read -r branch
  [ -n "$branch" ] || branch="$DEFAULT_BRANCH"
  printf 'Caminho do arquivo remoto: '
  IFS= read -r path
  [ -n "$path" ] || {
    printf 'Caminho inválido.\n'
    return 1
  }
  local encoded_path repo_encoded
  encoded_path=$(urlencode_path "$path") || return 1
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch")" \
    "" "$TMP_DIR/content.json"; then
    return 1
  fi
  sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
  [ -n "$sha" ] || {
    printf 'Não foi possível obter o SHA do arquivo.\n'
    return 1
  }
  printf 'Mensagem do commit de exclusão: '
  IFS= read -r message
  [ -n "$message" ] || message="Exclusão via GitHub Manager"
  printf 'Confirma a exclusão de %s? (s/n): ' "$path"
  IFS= read -r answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  payload=$(jq -n \
    --arg message "$message" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{message:$message,sha:$sha,branch:$branch}')
  encoded_path=$(urlencode_path "$path") || return 1
  if api DELETE \
    "/repos/$GITHUB_USER/$(urlencode "$SELECTED_REPO")/contents/$encoded_path" \
    "$payload"; then
    printf 'Arquivo excluído.\n'
  fi
}
urlencode_path() {
  local remaining component encoded separator
  remaining="$1"
  encoded=""
  separator=""
  while :; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    encoded="${encoded}${separator}$(urlencode "$component")" || return 1
    separator="/"
    [ -n "$remaining" ] || break
  done
  printf '%s' "$encoded"
}
validate_remote_folder() {
  local folder remaining component
  folder="$1"
  [ -n "$folder" ] || return 1
  case "$folder" in /*|*/|*//*|*\\*) return 1 ;; esac
  remaining="$folder"
  while :; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    case "$component" in ""|"."|"..") return 1 ;; esac
    [ -n "$remaining" ] || break
  done
  return 0
}
create_folder_main() {
  local folder repo_encoded path_encoded content payload status existing_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Caminho da pasta a criar na MAIN PRINCIPAL: '
  IFS= read -r folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1
  # Evita erro HTTP 422 quando a pasta já possui o marcador .gitkeep.
  existing_status=$(curl -sS -o "$TMP_DIR/folder-main-existing.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$DEFAULT_BRANCH")") || {
    printf 'Falha de comunicação ao verificar a pasta.\n'
    return 1
  }
  case "$existing_status" in
    200)
      printf 'A pasta %s já existe na MAIN PRINCIPAL. Nenhuma alteração realizada.\n' "$folder"
      return 0
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar a pasta (HTTP %s).\n' "$existing_status"
      jq -r '.message // empty' "$TMP_DIR/folder-main-existing.json" 2>/dev/null
      return 1
      ;;
  esac
  content=$(printf '%s' 'Pasta criada pelo GitHub Manager.' | base64 | tr -d '\r\n') || return 1
  payload=$(jq -n \
    --arg message "Criar pasta $folder na MAIN PRINCIPAL" \
    --arg content "$content" \
    --arg branch "$DEFAULT_BRANCH" \
    '{message:$message,content:$content,branch:$branch}') || return 1
  status=$(curl -sS -o "$TMP_DIR/create-folder-main.json" -w '%{http_code}' \
    -X PUT \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded") || {
    printf 'Falha de comunicação ao criar a pasta.\n'
    return 1
  }
  case "$status" in
    200|201)
      printf 'Pasta criada na MAIN PRINCIPAL: %s (branch %s)\n' "$folder" "$DEFAULT_BRANCH"
      ;;
    *)
      printf 'Falha ao criar pasta (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/create-folder-main.json" 2>/dev/null
      return 1
      ;;
  esac
}
delete_folder_main() {
  local folder repo_encoded tree_status path encoded_path content_sha payload status confirm
  ensure_login || return 1
  select_repository || return 1
  printf 'Caminho da pasta a deletar na MAIN PRINCIPAL: '
  IFS= read -r folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  tree_status=$(curl -sS -o "$TMP_DIR/delete-folder-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$(urlencode "$DEFAULT_BRANCH")?recursive=1") || {
    printf 'Falha ao consultar a árvore do repositório.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/delete-folder-tree.json" 2>/dev/null
    return 1
  }
  jq -r --arg prefix "$folder/" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/delete-folder-tree.json" > "$TMP_DIR/delete-folder-files.txt"
  if [ ! -s "$TMP_DIR/delete-folder-files.txt" ]; then
    printf 'Nenhum arquivo encontrado na pasta "%s" na MAIN PRINCIPAL.\n' "$folder"
    return 1
  fi
  printf '\nArquivos que serão excluídos da pasta "%s":\n' "$folder"
  cat "$TMP_DIR/delete-folder-files.txt"
  printf '\nDigite DELETAR para confirmar a exclusão de todos esses arquivos: '
  IFS= read -r confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    encoded_path=$(urlencode_path "$path") || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")") || {
      printf 'Falha de comunicação ao consultar: %s\n' "$path"
      return 1
    }
    [ "$status" = 200 ] || {
      printf 'Falha ao consultar "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-folder-content.json" 2>/dev/null
      return 1
    }
    content_sha=$(jq -r '.sha // empty' "$TMP_DIR/delete-folder-content.json")
    [ -n "$content_sha" ] || {
      printf 'Não foi possível obter o SHA de: %s\n' "$path"
      return 1
    }
    payload=$(jq -n --arg message "Excluir $path da MAIN via GitHub Manager" --arg sha "$content_sha" --arg branch "$DEFAULT_BRANCH" '{message:$message,sha:$sha,branch:$branch}') || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-result.json" -w '%{http_code}' \
      -X DELETE \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path") || {
      printf 'Falha de comunicação ao excluir: %s\n' "$path"
      return 1
    }
    case "$status" in
      200) printf 'Excluído: %s\n' "$path" ;;
      *)
        printf 'Falha ao excluir "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
        jq -r '.message // empty' "$TMP_DIR/delete-folder-result.json" 2>/dev/null
        return 1
        ;;
    esac
  done < "$TMP_DIR/delete-folder-files.txt"
  printf '\nConteúdo da pasta "%s" excluído da MAIN PRINCIPAL.\n' "$folder"
  printf 'Observação: o GitHub não armazena diretórios vazios; a pasta deixa de aparecer quando todos os arquivos são removidos.\n'
}
create_secondary_branch() {
  local branch_name repo_encoded base_ref_encoded sha payload
  select_repository || return 1
  printf 'Nome da BRANCH secundária: '
  IFS= read -r branch_name
  [ -n "$branch_name" ] || { printf 'Nome inválido.\n'; return 1; }
  if command -v git >/dev/null 2>&1 && ! git check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1; then
    printf 'Nome de branch inválido segundo as regras do Git.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  base_ref_encoded=$(urlencode_path "$DEFAULT_BRANCH") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$base_ref_encoded" "" "$TMP_DIR/base-ref.json"; then
    return 1
  fi
  sha=$(jq -r '.object.sha // empty' "$TMP_DIR/base-ref.json")
  [ -n "$sha" ] || { printf 'Não foi possível obter o commit da branch principal.\n'; return 1; }
  payload=$(jq -n --arg ref "refs/heads/$branch_name" --arg sha "$sha" '{ref:$ref,sha:$sha}') || return 1
  if api POST "/repos/$GITHUB_USER/$repo_encoded/git/refs" "$payload" "$TMP_DIR/new-branch.json"; then
    printf 'BRANCH secundária criada: %s (base: %s)\n' "$branch_name" "$DEFAULT_BRANCH"
  else
    return 1
  fi
}
delete_secondary_branch() {
  local branch_name repo_encoded branch_encoded confirm status
  ensure_login || return 1
  select_repository || return 1
  printf '\nBRANCH PRINCIPAL protegida: %s\n' "$DEFAULT_BRANCH"
  printf 'Nome exato da BRANCH secundária a deletar: '
  IFS= read -r branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: não é permitido deletar a BRANCH PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  branch_encoded=$(urlencode "$branch_name") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$branch_encoded" "" "$TMP_DIR/branch-to-delete.json"; then
    printf 'A branch informada não foi localizada ou não pode ser consultada.\n'
    return 1
  fi
  printf '\nRepositório: %s\nBranch: %s\n' "$SELECTED_REPO" "$branch_name"
  printf 'Digite DELETAR para confirmar: '
  IFS= read -r confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  status=$(curl -sS -o "$TMP_DIR/delete-secondary-branch.json" -w '%{http_code}' \
    -X DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$branch_encoded") || {
    printf 'Falha de comunicação ao deletar a branch.\n'
    return 1
  }
  case "$status" in
    204) printf 'BRANCH secundária "%s" deletada com sucesso.\n' "$branch_name" ;;
    *)
      printf 'Falha ao deletar a branch (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-secondary-branch.json" 2>/dev/null
      return 1
      ;;
  esac
}
rename_secondary_branch() {
  local old_branch new_branch repo_encoded old_ref_encoded new_ref_encoded sha payload confirm status
  ensure_login || return 1
  select_repository || return 1
  printf '\nBRANCH PRINCIPAL protegida: %s\n' "$DEFAULT_BRANCH"
  printf 'Nome atual da BRANCH secundária: '
  IFS= read -r old_branch
  [ -n "$old_branch" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$old_branch" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: não é permitido renomear a BRANCH PRINCIPAL.\n'
    return 1
  fi
  printf 'Novo nome da BRANCH secundária: '
  IFS= read -r new_branch
  [ -n "$new_branch" ] || {
    printf 'Novo nome de branch inválido.\n'
    return 1
  }
  [ "$old_branch" != "$new_branch" ] || {
    printf 'O nome novo é igual ao nome atual. Nenhuma alteração realizada.\n'
    return 1
  }
  if [ "$new_branch" = "$DEFAULT_BRANCH" ]; then
    printf 'O novo nome não pode ser o da BRANCH PRINCIPAL.\n'
    return 1
  fi
  if command -v git >/dev/null 2>&1 && ! git check-ref-format "refs/heads/$new_branch" >/dev/null 2>&1; then
    printf 'Novo nome de branch inválido segundo as regras do Git.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  old_ref_encoded=$(urlencode_path "$old_branch") || return 1
  new_ref_encoded=$(urlencode_path "$new_branch") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$old_ref_encoded" "" "$TMP_DIR/rename-branch-old-ref.json"; then
    printf 'A BRANCH atual não foi localizada.\n'
    return 1
  fi
  sha=$(jq -r '.object.sha // empty' "$TMP_DIR/rename-branch-old-ref.json")
  [ -n "$sha" ] || {
    printf 'Não foi possível obter o commit da BRANCH atual.\n'
    return 1
  }
  status=$(curl -sS -o "$TMP_DIR/rename-branch-new-check.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$new_ref_encoded") || {
    printf 'Falha ao verificar o novo nome da BRANCH.\n'
    return 1
  }
  case "$status" in
    200)
      printf 'Já existe uma BRANCH chamada "%s".\n' "$new_branch"
      return 1
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar o novo nome (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/rename-branch-new-check.json" 2>/dev/null
      return 1
      ;;
  esac
  printf '\nRepositório: %s\nBRANCH atual: %s\nNovo nome: %s\n' "$SELECTED_REPO" "$old_branch" "$new_branch"
  printf 'A operação criará a nova referência e depois excluirá a antiga. Digite RENOMEAR para confirmar: '
  IFS= read -r confirm
  [ "$confirm" = RENOMEAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  payload=$(jq -n --arg ref "refs/heads/$new_branch" --arg sha "$sha" '{ref:$ref,sha:$sha}') || return 1
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/refs" "$payload" "$TMP_DIR/rename-branch-create.json"; then
    printf 'Não foi possível criar a nova BRANCH; a antiga foi mantida.\n'
    return 1
  fi
  status=$(curl -sS -o "$TMP_DIR/rename-branch-delete.json" -w '%{http_code}' \
    -X DELETE \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$old_ref_encoded") || {
    printf 'A nova BRANCH foi criada, mas houve falha de comunicação ao excluir a antiga.\n'
    printf 'Nova BRANCH: %s | BRANCH antiga ainda pode existir: %s\n' "$new_branch" "$old_branch"
    return 1
  }
  case "$status" in
    204) printf 'BRANCH renomeada: %s -> %s\n' "$old_branch" "$new_branch" ;;
    *)
      printf 'A nova BRANCH foi criada, mas a antiga não foi excluída (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/rename-branch-delete.json" 2>/dev/null
      printf 'Verifique as duas BRANCHES no GitHub antes de repetir a operação.\n'
      return 1
      ;;
  esac
}
create_folder_secondary_branch() {
  local branch_name folder repo_encoded path_encoded content payload status existing_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária existente: '
  IFS= read -r branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Informe uma branch secundária, não a MAIN PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET \
    "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch_name")" \
    "" "$TMP_DIR/secondary-branch.json"; then
    return 1
  fi
  printf 'Caminho da pasta a criar na BRANCH secundária: '
  IFS= read -r folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1
  existing_status=$(curl -sS -o "$TMP_DIR/folder-branch-existing.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$branch_name")") || {
    printf 'Falha de comunicação ao verificar a pasta.\n'
    return 1
  }
  case "$existing_status" in
    200)
      printf 'A pasta %s já existe na BRANCH %s. Nenhuma alteração realizada.\n' "$folder" "$branch_name"
      return 0
      ;;
    404) ;;
    *)
      printf 'Falha ao verificar a pasta (HTTP %s).\n' "$existing_status"
      jq -r '.message // empty' "$TMP_DIR/folder-branch-existing.json" 2>/dev/null
      return 1
      ;;
  esac
  content=$(printf '%s' 'Pasta criada pelo GitHub Manager.' | base64 | tr -d '\r\n') || return 1
  payload=$(jq -n \
    --arg message "Criar pasta $folder na branch $branch_name" \
    --arg content "$content" \
    --arg branch "$branch_name" \
    '{message:$message,content:$content,branch:$branch}') || return 1
  status=$(curl -sS -o "$TMP_DIR/create-folder-branch.json" -w '%{http_code}' \
    -X PUT \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded") || {
    printf 'Falha de comunicação ao criar a pasta.\n'
    return 1
  }
  case "$status" in
    200|201)
      printf 'Pasta criada na BRANCH secundária: %s (branch %s)\n' "$folder" "$branch_name"
      ;;
    *)
      printf 'Falha ao criar pasta (HTTP %s).\n' "$status"
      jq -r '.message // empty' "$TMP_DIR/create-folder-branch.json" 2>/dev/null
      return 1
      ;;
  esac
}
delete_folder_secondary_branch() {
  local branch_name folder repo_encoded tree_status path encoded_path content_sha payload status confirm
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária existente: '
  IFS= read -r branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: informe uma BRANCH secundária, não a MAIN PRINCIPAL.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/branches/$(urlencode "$branch_name")" "" "$TMP_DIR/secondary-branch-to-delete-folder.json"; then
    printf 'A BRANCH secundária informada não foi localizada ou não pode ser consultada.\n'
    return 1
  fi
  printf 'Caminho da pasta a deletar na BRANCH secundária: '
  IFS= read -r folder
  folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$folder" || {
    printf 'Caminho de pasta inválido. Exemplo: docs/guias\n'
    return 1
  }
  tree_status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$(urlencode "$branch_name")?recursive=1") || {
    printf 'Falha ao consultar a árvore da BRANCH secundária.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore da BRANCH (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-tree.json" 2>/dev/null
    return 1
  }
  jq -r --arg prefix "$folder/" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/delete-folder-branch-tree.json" > "$TMP_DIR/delete-folder-branch-files.txt"
  if [ ! -s "$TMP_DIR/delete-folder-branch-files.txt" ]; then
    printf 'Nenhum arquivo encontrado na pasta "%s" na BRANCH "%s".\n' "$folder" "$branch_name"
    return 1
  fi
  printf '\nRepositório: %s\nBRANCH secundária: %s\n' "$SELECTED_REPO" "$branch_name"
  printf 'Arquivos que serão excluídos da pasta "%s":\n' "$folder"
  cat "$TMP_DIR/delete-folder-branch-files.txt"
  printf '\nDigite DELETAR para confirmar a exclusão de todos esses arquivos: '
  IFS= read -r confirm
  [ "$confirm" = DELETAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    encoded_path=$(urlencode_path "$path") || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-content.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path?ref=$(urlencode "$branch_name")") || {
      printf 'Falha de comunicação ao consultar: %s\n' "$path"
      return 1
    }
    [ "$status" = 200 ] || {
      printf 'Falha ao consultar "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
      jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-content.json" 2>/dev/null
      return 1
    }
    content_sha=$(jq -r '.sha // empty' "$TMP_DIR/delete-folder-branch-content.json")
    [ -n "$content_sha" ] || {
      printf 'Não foi possível obter o SHA de: %s\n' "$path"
      return 1
    }
    payload=$(jq -n --arg message "Excluir $path da BRANCH $branch_name via GitHub Manager" --arg sha "$content_sha" --arg branch "$branch_name" '{message:$message,sha:$sha,branch:$branch}') || return 1
    status=$(curl -sS -o "$TMP_DIR/delete-folder-branch-result.json" -w '%{http_code}' \
      -X DELETE \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" \
      "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path") || {
      printf 'Falha de comunicação ao excluir: %s\n' "$path"
      return 1
    }
    case "$status" in
      200) printf 'Excluído: %s\n' "$path" ;;
      *)
        printf 'Falha ao excluir "%s" (HTTP %s). Interrompendo.\n' "$path" "$status"
        jq -r '.message // empty' "$TMP_DIR/delete-folder-branch-result.json" 2>/dev/null
        return 1
        ;;
    esac
  done < "$TMP_DIR/delete-folder-branch-files.txt"
  printf '\nConteúdo da pasta "%s" excluído da BRANCH "%s".\n' "$folder" "$branch_name"
  printf 'Observação: o GitHub não armazena diretórios vazios; a pasta deixa de aparecer quando todos os arquivos são removidos.\n'
}
rename_folder_secondary_branch() {
  local branch_name old_folder new_folder repo_encoded branch_ref_encoded branch_sha commit_tree_sha tree_status
  local old_prefix new_prefix confirm payload new_tree_sha new_commit_sha update_status
  ensure_login || return 1
  select_repository || return 1
  printf 'Nome da BRANCH secundária: '
  IFS= read -r branch_name
  [ -n "$branch_name" ] || {
    printf 'Nome de branch inválido.\n'
    return 1
  }
  if [ "$branch_name" = "$DEFAULT_BRANCH" ]; then
    printf 'Operação bloqueada: renomeie pastas somente em uma BRANCH secundária.\n'
    return 1
  fi
  repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
  branch_ref_encoded=$(urlencode_path "$branch_name") || return 1
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$branch_ref_encoded" "" "$TMP_DIR/rename-folder-branch-ref.json"; then
    printf 'A BRANCH secundária não foi localizada.\n'
    return 1
  fi
  branch_sha=$(jq -r '.object.sha // empty' "$TMP_DIR/rename-folder-branch-ref.json")
  [ -n "$branch_sha" ] || {
    printf 'Não foi possível obter o commit da BRANCH.\n'
    return 1
  }
  printf 'Caminho atual da pasta: '
  IFS= read -r old_folder
  old_folder=$(printf '%s' "$old_folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$old_folder" || {
    printf 'Caminho atual inválido. Exemplo: docs/guias\n'
    return 1
  }
  printf 'Novo caminho da pasta: '
  IFS= read -r new_folder
  new_folder=$(printf '%s' "$new_folder" | sed 's#^/*##;s#/*$##')
  validate_remote_folder "$new_folder" || {
    printf 'Novo caminho inválido. Exemplo: docs/manuais\n'
    return 1
  }
  [ "$old_folder" != "$new_folder" ] || {
    printf 'O caminho novo é igual ao atual. Nenhuma alteração realizada.\n'
    return 1
  }
  old_prefix="$old_folder/"
  new_prefix="$new_folder/"
  if ! api GET "/repos/$GITHUB_USER/$repo_encoded/git/commits/$branch_sha" "" "$TMP_DIR/rename-folder-commit.json"; then
    return 1
  fi
  commit_tree_sha=$(jq -r '.tree.sha // empty' "$TMP_DIR/rename-folder-commit.json")
  [ -n "$commit_tree_sha" ] || {
    printf 'Não foi possível obter a árvore da BRANCH.\n'
    return 1
  }
  tree_status=$(curl -sS -o "$TMP_DIR/rename-folder-tree.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/trees/$commit_tree_sha?recursive=1") || {
    printf 'Falha ao consultar a árvore da BRANCH.\n'
    return 1
  }
  [ "$tree_status" = 200 ] || {
    printf 'Falha ao consultar a árvore (HTTP %s).\n' "$tree_status"
    jq -r '.message // empty' "$TMP_DIR/rename-folder-tree.json" 2>/dev/null
    return 1
  }
  if [ "$(jq -r '.truncated // false' "$TMP_DIR/rename-folder-tree.json")" = true ]; then
    printf 'A árvore do repositório foi truncada pela API. Renomeação cancelada para evitar alterações incompletas.\n'
    return 1
  fi
  if ! jq -e --arg prefix "$old_prefix" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix)))' \
    "$TMP_DIR/rename-folder-tree.json" >/dev/null 2>&1; then
    printf 'A pasta atual não contém arquivos ou não foi encontrada: %s\n' "$old_folder"
    return 1
  fi
  if jq -e --arg prefix "$new_prefix" --arg exact "$new_folder" \
    '.tree[]? | select(.path == $exact or (.path | startswith($prefix)))' \
    "$TMP_DIR/rename-folder-tree.json" >/dev/null 2>&1; then
    printf 'O destino já existe: %s. Renomeação cancelada para evitar sobrescrita.\n' "$new_folder"
    return 1
  fi
  printf '\nRepositório: %s\nBRANCH secundária: %s\nPasta atual: %s\nNovo caminho: %s\n' \
    "$SELECTED_REPO" "$branch_name" "$old_folder" "$new_folder"
  printf 'Arquivos que serão movidos:\n'
  jq -r --arg prefix "$old_prefix" '.tree[]? | select(.type == "blob" and (.path | startswith($prefix))) | .path' \
    "$TMP_DIR/rename-folder-tree.json"
  printf '\nDigite RENOMEAR para confirmar: '
  IFS= read -r confirm
  [ "$confirm" = RENOMEAR ] || {
    printf 'Operação cancelada.\n'
    return 0
  }
  payload=$(jq -c --arg old_prefix "$old_prefix" --arg new_prefix "$new_prefix" --arg base_tree "$commit_tree_sha" '
    {base_tree:$base_tree,tree:[
      (.tree[]? | select(.type == "blob" and (.path | startswith($old_prefix))) |
        {path:( $new_prefix + (.path | ltrimstr($old_prefix))),mode:.mode,type:"blob",sha:.sha}),
      (.tree[]? | select(.type == "blob" and (.path | startswith($old_prefix))) |
        {path:.path,mode:.mode,type:"blob",sha:null})
    ]}
  ' "$TMP_DIR/rename-folder-tree.json") || {
    printf 'Não foi possível preparar a árvore da renomeação.\n'
    return 1
  }
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/trees" "$payload" "$TMP_DIR/rename-folder-new-tree.json"; then
    printf 'Não foi possível criar a nova árvore. A BRANCH não foi alterada.\n'
    return 1
  fi
  new_tree_sha=$(jq -r '.sha // empty' "$TMP_DIR/rename-folder-new-tree.json")
  [ -n "$new_tree_sha" ] || {
    printf 'A API não retornou o SHA da nova árvore.\n'
    return 1
  }
  payload=$(jq -n \
    --arg message "Renomear pasta $old_folder para $new_folder" \
    --arg tree "$new_tree_sha" \
    --arg parent "$branch_sha" \
    '{message:$message,tree:$tree,parents:[$parent]}') || return 1
  if ! api POST "/repos/$GITHUB_USER/$repo_encoded/git/commits" "$payload" "$TMP_DIR/rename-folder-new-commit.json"; then
    printf 'Não foi possível criar o commit. A BRANCH não foi alterada.\n'
    return 1
  fi
  new_commit_sha=$(jq -r '.sha // empty' "$TMP_DIR/rename-folder-new-commit.json")
  [ -n "$new_commit_sha" ] || {
    printf 'A API não retornou o SHA do novo commit.\n'
    return 1
  }
  payload=$(jq -n --arg sha "$new_commit_sha" '{sha:$sha,force:false}') || return 1
  update_status=$(curl -sS -o "$TMP_DIR/rename-folder-update-ref.json" -w '%{http_code}' \
    -X PATCH \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload" \
    "$API_URL/repos/$GITHUB_USER/$repo_encoded/git/refs/heads/$branch_ref_encoded") || {
    printf 'Falha de comunicação ao atualizar a BRANCH.\n'
    return 1
  }
  case "$update_status" in
    200)
      printf 'Pasta renomeada com sucesso: %s -> %s (BRANCH: %s)\n' "$old_folder" "$new_folder" "$branch_name"
      printf 'Os arquivos e subpastas foram preservados no novo caminho.\n'
      ;;
    *)
      printf 'Falha ao atualizar a BRANCH (HTTP %s). A árvore e o commit foram preparados, mas a BRANCH não foi atualizada.\n' "$update_status"
      jq -r '.message // empty' "$TMP_DIR/rename-folder-update-ref.json" 2>/dev/null
      return 1
      ;;
  esac
}
list_local_files() {
  printf '\nDiretório local: %s\n' "$PWD"
  find "$PWD" -maxdepth 1 -type f -print | sort
}
change_current_directory() {
  local requested_dir
  printf 'Diretório atual: %s\nNovo diretório: ' "$PWD"
  IFS= read -r requested_dir
  [ -n "$requested_dir" ] || { printf 'Diretório não informado.\n'; return 1; }
  case "$requested_dir" in '~') requested_dir="$HOME" ;; '~/'*) requested_dir="$HOME/${requested_dir#\~/}" ;; esac
  [ -d "$requested_dir" ] || { printf 'Diretório não encontrado: %s\n' "$requested_dir"; return 1; }
  cd -- "$requested_dir" || return 1
  printf 'Diretório corrente alterado para: %s\n' "$PWD"
}
search_file() {
  local page count repo default_branch branch path search_term
  ensure_login || return 1
  printf 'Nome ou trecho do nome do arquivo: '
  IFS= read -r search_term
  [ -n "$search_term" ] || {
    printf 'Termo de pesquisa inválido.\n'
    return 1
  }
  page=1
  while :; do
    if ! api GET \
      "/user/repos?affiliation=owner&per_page=100&page=$page&sort=full_name" \
      "" "$TMP_DIR/repos.json"; then
      return 1
    fi
    count=$(jq 'length' "$TMP_DIR/repos.json")
    [ "$count" -gt 0 ] || break
    while IFS="$(printf '\t')" read -r repo default_branch; do
      [ -n "$repo" ] || continue
      if ! api GET \
        "/repos/$GITHUB_USER/$(urlencode "$repo")/branches?per_page=100" \
        "" "$TMP_DIR/branches.json"; then
        continue
      fi
      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        if ! api GET \
          "/repos/$GITHUB_USER/$(urlencode "$repo")/git/trees/$(urlencode "$branch")?recursive=1" \
          "" "$TMP_DIR/tree.json"; then
          continue
        fi
        jq -r --arg term "$search_term" '
          .tree[]?
          | select(.type == "blob")
          | select(.path | ascii_downcase | contains($term | ascii_downcase))
          | .path
        ' "$TMP_DIR/tree.json" |
        while IFS= read -r path; do
          printf 'Repositório: %s | Branch: %s | Caminho: %s\n' \
            "$repo" "$branch" "$path"
        done
      done < <(jq -r '.[].name' "$TMP_DIR/branches.json")
    done < <(
      jq -r '.[] | [.name,.default_branch] | @tsv' "$TMP_DIR/repos.json"
    )
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
}
clone_third_party_repository() {
  local url destination
  command -v git >/dev/null 2>&1 || {
    printf 'Git não está instalado.\n'
    return 1
  }
  printf 'URL HTTPS ou SSH do repositório: '
  IFS= read -r url
  [ -n "$url" ] || {
    printf 'URL inválida.\n'
    return 1
  }
  printf 'Diretório de destino (ENTER para usar o padrão): '
  IFS= read -r destination
  if [ -n "$destination" ]; then
    git clone "$url" "$destination"
  else
    git clone "$url"
  fi
}
delete_repository() {
  local name answer
  ensure_login || return 1
  printf 'Nome do repositório a excluir: '
  IFS= read -r name
  valid_name "$name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'ATENÇÃO: excluir permanentemente %s/%s? (s/n): ' "$GITHUB_USER" "$name"
  IFS= read -r answer
  case "$answer" in
    s|S|sim|SIM) ;;
    *) printf 'Operação cancelada.\n'; return 0 ;;
  esac
  if api DELETE "/repos/$GITHUB_USER/$(urlencode "$name")"; then
    printf 'Repositório excluído.\n'
  fi
}
rename_repository() {
  local old_name new_name payload
  ensure_login || return 1
  printf 'Nome atual do repositório: '
  IFS= read -r old_name
  valid_name "$old_name" || {
    printf 'Nome inválido.\n'
    return 1
  }
  printf 'Novo nome do repositório: '
  IFS= read -r new_name
  valid_name "$new_name" || {
    printf 'Novo nome inválido.\n'
    return 1
  }
  payload=$(jq -n --arg name "$new_name" '{name:$name}')
  if api PATCH "/repos/$GITHUB_USER/$(urlencode "$old_name")" "$payload"; then
    printf 'Repositório renomeado para: %s\n' "$new_name"
  fi
}
show_menu() {
  if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
    clear 2>/dev/null || :
  fi
  printf '%s\n' '================================================================='
  printf '                    GIT / GITHUB Menu\n'
  printf '%s\n' '================================================================='
  printf 'Usuário GitHub: %s\n\n' "${GITHUB_USER:-Não autenticado}"
  printf '%s\n' \
    '1  - Listar repositórios da MAIN PRINCIPAL, incluindo subpastas' \
    '2  - Criar repositório na MAIN' \
    '3  - Renomear repositório da MAIN' \
    '4  - Deletar repositório da MAIN' \
    '5  - Criar BRANCH secundária' \
    '6  - Renomear BRANCH secundária' \
    '7  - Deletar BRANCH secundária' \
    '8  - Criar pasta na MAIN PRINCIPAL' \
    '9  - Deletar pasta da MAIN PRINCIPAL' \
    '10 - Criar pasta na BRANCH secundária' \
    '11 - Renomear pasta da BRANCH secundária' \
    '12 - Deletar pasta da BRANCH secundária' \
    '13 - Pesquisar arquivo e mostrar branch e caminho' \
    '14 - Baixar arquivo remoto para a pasta local' \
    '15 - Enviar arquivo local ao GitHub' \
    '16 - Excluir arquivo remoto pelo nome/caminho' \
    '17 - Verificar arquivos na pasta local corrente' \
    '18 - Mudar diretório corrente' \
    '19 - Clonar repositório GitHub de terceiros' \
    '20 - Trocar de usuário GitHub' \
    '' \
    '0  - Sair'
  printf '%s\n' '================================================================='
  printf 'Escolha uma opção: '
}
main() {
  local option
  while :; do
    show_menu
    if ! IFS= read -r option; then
      printf '\nEntrada encerrada; saindo do menu.\n'
      break
    fi
    case "$option" in
      1) list_repositories; pause ;;
      2) create_repository_main; pause ;;
      3) rename_repository; pause ;;
      4) delete_repository; pause ;;
      5) create_secondary_branch; pause ;;
      6) rename_secondary_branch; pause ;;
      7) delete_secondary_branch; pause ;;
      8) create_folder_main; pause ;;
      9) delete_folder_main; pause ;;
      10) create_folder_secondary_branch; pause ;;
      11) rename_folder_secondary_branch; pause ;;
      12) delete_folder_secondary_branch; pause ;;
      13) search_file; pause ;;
      14) download_file; pause ;;
      15) upload_file; pause ;;
      16) delete_remote_file; pause ;;
      17) list_local_files; pause ;;
      18) change_current_directory; pause ;;
      19) clone_third_party_repository; pause ;;
      20) logout_github; login_github; pause ;;
      0) logout_github; exit 0 ;;
      *) printf '\nOpção inválida.\n'; pause ;;
    esac
  done
}
command -v curl >/dev/null 2>&1 || {
  printf 'Erro: curl não está instalado.\n'
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'Erro: jq não está instalado.\n'
  exit 1
}
if [ ! -t 0 ]; then
  printf 'Erro: este programa precisa ser executado em um terminal interativo.\n' >&2
  printf 'Execute com: bash "%s"\n' "$0" >&2
  exit 2
fi

show_banner
if ! login_github; then
  printf '\nLogin não concluído. Programa encerrado.\n'
  exit 1
fi
main
