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

valid_name() {
    case "$1" in
        ""|*[!a-zA-Z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

urlencode() {
    jq -nr --arg value "$1" '$value|@uri'
}

urlencode_path() {
    local remaining component encoded separator
    remaining="$1"
    encoded=""
    separator=""

    while :; do
        case "$remaining" in
            */*)
                component="${remaining%%/*}"
                remaining="${remaining#*/}"
                ;;
            *)
                component="$remaining"
                remaining=""
                ;;
        esac

        encoded="${encoded}${separator}$(urlencode "$component")" || return 1
        separator="/"
        [ -n "$remaining" ] || break
    done

    printf '%s' "$encoded"
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
            "$API_URL$endpoint" \
            --data-binary "$data")
    else
        status=$(curl -sS -o "$output" -w '%{http_code}' \
            -X "$method" \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "X-GitHub-Api-Version: $API_VERSION" \
            "$API_URL$endpoint")
    fi

    case "$status" in
        200|201|202|204)
            return 0
            ;;
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

    [ -n "$login" ] || {
        printf 'Login inválido.\n'
        return 1
    }

    printf 'PERSONAL ACCESS TOKEN (PAT): '
    IFS= read -r -s token
    printf '\n'

    [ -n "$token" ] || {
        printf 'Token não informado.\n'
        return 1
    }

    GITHUB_USER="$login"
    GITHUB_TOKEN="$token"

    if ! api GET "/user" "" "$TMP_DIR/user.json"; then
        GITHUB_USER=""
        GITHUB_TOKEN=""
        return 1
    fi

    response=$(jq -r '.login // empty' "$TMP_DIR/user.json")

    [ -n "$response" ] || {
        printf 'Não foi possível validar o usuário.\n'
        GITHUB_USER=""
        GITHUB_TOKEN=""
        return 1
    }

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
        '{name:$name,description:$description,private:$private,auto_init:true}') || return 1

    if api POST "/user/repos" "$payload"; then
        printf '\nRepositório criado: %s/%s\n' "$GITHUB_USER" "$name"
    fi
}

validate_remote_folder() {
    local folder remaining component

    folder="$1"
    [ -n "$folder" ] || return 1

    case "$folder" in
        /*|*/|*//*|*\\*) return 1 ;;
    esac

    remaining="$folder"

    while :; do
        case "$remaining" in
            */*)
                component="${remaining%%/*}"
                remaining="${remaining#*/}"
                ;;
            *)
                component="$remaining"
                remaining=""
                ;;
        esac

        case "$component" in
            ""|"."|"..") return 1 ;;
        esac

        [ -n "$remaining" ] || break
    done

    return 0
}

# OPÇÃO 5: criar pasta na branch principal.
# A pasta é representada por um arquivo .gitkeep.
create_folder_main() {
    local folder repo_encoded path_encoded content payload status existing_status

    ensure_login || return 1
    select_repository || return 1

    printf 'Caminho da pasta a criar na MAIN PRINCIPAL: '
    IFS= read -r folder
    folder=$(printf '%s' "$folder" | sed 's#^/*##;s#/*$##')

    validate_remote_folder "$folder" || {
        printf 'Caminho inválido. Exemplo: docs/guias\n'
        return 1
    }

    repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
    path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1

    # Verifica previamente se o marcador da pasta já existe.
    existing_status=$(curl -sS \
        -o "$TMP_DIR/folder-main-existing.json" \
        -w '%{http_code}' \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$DEFAULT_BRANCH")") || {
        printf 'Falha de comunicação ao verificar a pasta.\n'
        return 1
    }

    case "$existing_status" in
        200)
            printf 'A pasta %s já possui .gitkeep na MAIN PRINCIPAL. Nenhuma alteração realizada.\n' "$folder"
            return 0
            ;;
        404)
            ;;
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

    status=$(curl -sS \
        -o "$TMP_DIR/create-folder-main.json" \
        -w '%{http_code}' \
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

create_secondary_branch() {
    local branch_name repo_encoded base_ref_encoded sha payload

    select_repository || return 1

    printf 'Nome da BRANCH secundária: '
    IFS= read -r branch_name

    [ -n "$branch_name" ] || {
        printf 'Nome inválido.\n'
        return 1
    }

    if command -v git >/dev/null 2>&1 &&
       ! git check-ref-format "refs/heads/$branch_name" >/dev/null 2>&1; then
        printf 'Nome de branch inválido segundo as regras do Git.\n'
        return 1
    fi

    repo_encoded=$(urlencode "$SELECTED_REPO") || return 1
    base_ref_encoded=$(urlencode_path "$DEFAULT_BRANCH") || return 1

    if ! api GET \
        "/repos/$GITHUB_USER/$repo_encoded/git/ref/heads/$base_ref_encoded" \
        "" "$TMP_DIR/base-ref.json"; then
        return 1
    fi

    sha=$(jq -r '.object.sha // empty' "$TMP_DIR/base-ref.json")

    [ -n "$sha" ] || {
        printf 'Não foi possível obter o commit da branch principal.\n'
        return 1
    }

    payload=$(jq -n \
        --arg ref "refs/heads/$branch_name" \
        --arg sha "$sha" \
        '{ref:$ref,sha:$sha}') || return 1

    if api POST "/repos/$GITHUB_USER/$repo_encoded/git/refs" \
        "$payload" "$TMP_DIR/new-branch.json"; then
        printf 'BRANCH secundária criada: %s (base: %s)\n' "$branch_name" "$DEFAULT_BRANCH"
    else
        return 1
    fi
}

# OPÇÃO 7: criar pasta em uma BRANCH secundária existente.
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
        printf 'Caminho inválido. Exemplo: docs/guias\n'
        return 1
    }

    path_encoded=$(urlencode_path "$folder/.gitkeep") || return 1

    existing_status=$(curl -sS \
        -o "$TMP_DIR/folder-branch-existing.json" \
        -w '%{http_code}' \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "$API_URL/repos/$GITHUB_USER/$repo_encoded/contents/$path_encoded?ref=$(urlencode "$branch_name")") || {
        printf 'Falha de comunicação ao verificar a pasta.\n'
        return 1
    }

    case "$existing_status" in
        200)
            printf 'A pasta %s já possui .gitkeep na BRANCH %s. Nenhuma alteração realizada.\n' "$folder" "$branch_name"
            return 0
            ;;
        404)
            ;;
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

    status=$(curl -sS \
        -o "$TMP_DIR/create-folder-branch.json" \
        -w '%{http_code}' \
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

upload_file() {
    local file remote_folder remote_path
    local encoded_repo encoded_path encoded_component
    local remaining component separator
    local content sha payload http_code

    ensure_login || return 1

    command -v base64 >/dev/null 2>&1 || {
        printf 'Erro: base64 não está disponível.\n'
        return 1
    }

    printf '\n=== ENVIAR ARQUIVO LOCAL AO GITHUB ===\n'
    printf 'Diretório local: %s\n' "$PWD"

    select_repository || return 1

    printf 'Pasta remota (ENTER para a raiz): '
    IFS= read -r remote_folder

    remote_folder=$(printf '%s' "$remote_folder" | sed 's#^/*##;s#/*$##')

    if [ -n "$remote_folder" ]; then
        validate_remote_folder "$remote_folder" || {
            printf 'Caminho de pasta inválido.\n'
            return 1
        }
    fi

    printf 'Nome do arquivo local: '
    IFS= read -r file

    case "$file" in
        ""|"."|".."|*/*|*\\*)
            printf 'Informe somente o nome do arquivo, sem caminhos.\n'
            return 1
            ;;
    esac

    [ -f "$PWD/$file" ] && [ -r "$PWD/$file" ] || {
        printf 'Arquivo não encontrado ou sem permissão de leitura: %s\n' "$file"
        return 1
    }

    if [ -n "$remote_folder" ]; then
        remote_path="$remote_folder/$file"
    else
        remote_path="$file"
    fi

    encoded_path=$(urlencode_path "$remote_path") || return 1
    encoded_repo=$(urlencode "$SELECTED_REPO") || return 1

    content=$(base64 < "$PWD/$file" | tr -d '\r\n') || {
        printf 'Falha ao codificar o arquivo.\n'
        return 1
    }

    http_code=$(curl -sS \
        -o "$TMP_DIR/content.json" \
        -w '%{http_code}' \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path?ref=$(urlencode "$DEFAULT_BRANCH")") || return 1

    sha=""
    case "$http_code" in
        200)
            sha=$(jq -r '.sha // empty' "$TMP_DIR/content.json")
            [ -n "$sha" ] || {
                printf 'Não foi possível obter o SHA do arquivo remoto.\n'
                return 1
            }
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
        '{message:$message,content:$content,branch:$branch} +
         (if $sha != "" then {sha:$sha} else {} end)') || return 1

    http_code=$(curl -sS \
        -o "$TMP_DIR/upload.json" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "X-GitHub-Api-Version: $API_VERSION" \
        -H 'Content-Type: application/json' \
        --data-binary "$payload" \
        "$API_URL/repos/$GITHUB_USER/$encoded_repo/contents/$encoded_path") || return 1

    case "$http_code" in
        200|201)
            jq -e '.content.sha and .commit.sha' "$TMP_DIR/upload.json" >/dev/null 2>&1 || {
                printf 'A API não confirmou o envio do arquivo.\n'
                jq -r '.message // empty' "$TMP_DIR/upload.json" 2>/dev/null
                return 1
            }

            printf '\nArquivo enviado com sucesso!\n'
            printf 'Arquivo local: %s/%s\n' "$PWD" "$file"
            printf 'Repositório: %s/%s\n' "$GITHUB_USER" "$SELECTED_REPO"
            printf 'Caminho remoto: %s\n' "$remote_path"
            printf 'Branch: %s\n' "$DEFAULT_BRANCH"
            printf 'Commit: %s\n' "$(jq -r '.commit.sha' "$TMP_DIR/upload.json")"
            ;;
        *)
            printf 'Falha ao enviar arquivo (HTTP %s).\n' "$http_code"
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
        printf 'Caminho sem nome de arquivo válido.\n'
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

    [ "$(jq -r '.type // empty' "$TMP_DIR/content.json")" = "file" ] || {
        printf 'O caminho informado não corresponde a um arquivo.\n'
        return 1
    }

    if ! jq -r '.content // empty' "$TMP_DIR/content.json" |
        tr -d '\n' | base64 -d > "$output"; then
        rm -f "$output"
        printf 'Falha ao gravar o arquivo local.\n'
        return 1
    fi

    printf '\nArquivo copiado para: %s\n' "$output"
}

delete_remote_file() {
    local branch path message sha payload answer encoded_path repo_encoded

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
    [ -n "$message" ] && : || message="Exclusão via GitHub Manager"

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
        '{message:$message,sha:$sha,branch:$branch}') || return 1

    if api DELETE \
        "/repos/$GITHUB_USER/$repo_encoded/contents/$encoded_path" \
        "$payload"; then
        printf 'Arquivo excluído.\n'
    fi
}

list_local_files() {
    printf '\nDiretório local: %s\n' "$PWD"
    find "$PWD" -maxdepth 1 -type f -print | sort
}

change_current_directory() {
    local requested_dir

    printf 'Diretório atual: %s\nNovo diretório: ' "$PWD"
    IFS= read -r requested_dir

    [ -n "$requested_dir" ] || {
        printf 'Diretório não informado.\n'
        return 1
    }

    case "$requested_dir" in
        '~') requested_dir="$HOME" ;;
        '~/'*) requested_dir="$HOME/${requested_dir#\~/}" ;;
    esac

    [ -d "$requested_dir" ] || {
        printf 'Diretório não encontrado: %s\n' "$requested_dir"
        return 1
    }

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

    payload=$(jq -n --arg name "$new_name" '{name:$name}') || return 1

    if api PATCH "/repos/$GITHUB_USER/$(urlencode "$old_name")" "$payload"; then
        printf 'Repositório renomeado para: %s\n' "$new_name"
    fi
}

show_menu() {
    clear 2>/dev/null

    printf '%s\n' '================================================================='
    printf '                 %s\n' "$PROGRAM_NAME"
    printf '%s\n' '================================================================='
    printf 'Usuário GitHub: %s\n\n' "${GITHUB_USER:-Não autenticado}"

    printf '%s\n' '--- REPOSITÓRIOS ---' \
        '1  - Listar repositórios da MAIN PRINCIPAL, incluindo subpastas' \
        '2  - Criar repositório na MAIN PRINCIPAL' \
        '3  - Renomear repositório' \
        '4  - Excluir repositório pelo nome' \
        '5  - Criar pasta na MAIN PRINCIPAL' \
        '6  - Criar BRANCH secundária' \
        '7  - Criar pasta na BRANCH secundária' \
        '' \
        '--- ARQUIVOS REMOTOS DO GITHUB ---' \
        '8  - Pesquisar arquivo e mostrar branch e caminho' \
        '9  - Baixar arquivo com o mesmo nome para a pasta local' \
        '10 - Enviar arquivo local ao GitHub' \
        '11 - Excluir arquivo remoto pelo nome/caminho' \
        '' \
        '--- ARQUIVOS E DIRETÓRIOS LOCAIS ---' \
        '12 - Verificar arquivos na pasta local corrente' \
        '13 - Mudar diretório corrente' \
        '' \
        '--- CLONAGEM ---' \
        '14 - Clonar repositório GitHub de terceiros' \
        '' \
        '--- SESSÃO ---' \
        '15 - Trocar de usuário GitHub' \
        '16 - Retornar à tela de login' \
        '' \
        '0  - Sair'

    printf '%s\n' '================================================================='
    printf 'Escolha uma opção: '
}

main() {
    local option

    while :; do
        show_menu
        IFS= read -r option || exit 0

        case "$option" in
            1) list_repositories; pause ;;
            2) create_repository_main; pause ;;
            3) rename_repository; pause ;;
            4) delete_repository; pause ;;
            5) create_folder_main; pause ;;
            6) create_secondary_branch; pause ;;
            7) create_folder_secondary_branch; pause ;;
            8) search_file; pause ;;
            9) download_file; pause ;;
            10) upload_file; pause ;;
            11) delete_remote_file; pause ;;
            12) list_local_files; pause ;;
            13) change_current_directory; pause ;;
            14) clone_third_party_repository; pause ;;
            15) logout_github; login_github; pause ;;
            16) logout_github; login_github; pause ;;
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

login_github
main
