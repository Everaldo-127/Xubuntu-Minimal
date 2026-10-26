#!/usr/bin/env bash
#
# repositorio.sh
# Gerenciador de configurações APT e aptitude.
# Bash 3.x+
#
# 1 - Comparar somente diferenças
# 2 - Fazer backup
# 3 - Atualizar configurações
# 4 - Restaurar backup
# 0 - Sair

set -u

WORKDIR="$HOME/apt-config-manager"
STAGE="$WORKDIR/arquivos_oficiais"
BACKUPDIR="$WORKDIR/backups"
DOWNLOADDIR="$WORKDIR/download"
LASTBACKUP="$WORKDIR/ultimo_backup"

# Evita executar como root quando iniciado via sudo.
if [ "$(id -u)" -eq 0 ] &&
   [ -n "${SUDO_USER:-}" ] &&
   [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
        exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
    fi
fi

mkdir -p "$WORKDIR" "$STAGE" "$BACKUPDIR" "$DOWNLOADDIR" || exit 1

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

for CMD in apt-get dpkg-deb diff find tar grep; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERRO: comando obrigatório ausente: $CMD"
        exit 1
    fi
done

pausar() {
    printf '\nPressione ENTER para continuar...'
    read -r RESP
}

titulo() {
    clear 2>/dev/null || true
    echo "========================================"
    echo " GERENCIADOR DE CONFIGURAÇÕES APT"
    echo "========================================"
    echo
}

protegido() {
    case "$1" in
        /etc/apt/sources.list|\
        /etc/apt/sources.list.d/*|\
        /etc/apt/trusted.gpg|\
        /etc/apt/trusted.gpg.d/*|\
        /etc/apt/keyrings/*|\
        /etc/apt/preferences|\
        /etc/apt/preferences.d/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

baixar_referencias() {
    echo "Baixando pacotes dos repositórios APT configurados..."

    mkdir -p "$DOWNLOADDIR" "$STAGE" || return 1
    rm -f "$DOWNLOADDIR"/*.deb

    (
        cd "$DOWNLOADDIR" || exit 1
        apt-get download apt
    ) || {
        echo "ERRO: não foi possível baixar o pacote apt."
        return 1
    }

    (
        cd "$DOWNLOADDIR" || exit 1
        apt-get download aptitude
    ) || echo "AVISO: pacote aptitude indisponível."

    rm -rf "$STAGE/apt" "$STAGE/aptitude"
    mkdir -p "$STAGE/apt" "$STAGE/aptitude" || return 1

    APT_DEB=""
    APTITUDE_DEB=""

    for F in "$DOWNLOADDIR"/*.deb; do
        [ -f "$F" ] || continue

        case "$(basename "$F")" in
            apt_*.deb) APT_DEB="$F" ;;
            aptitude_*.deb) APTITUDE_DEB="$F" ;;
        esac
    done

    if [ -z "$APT_DEB" ]; then
        echo "ERRO: arquivo .deb do pacote apt não encontrado."
        return 1
    fi

    dpkg-deb -x "$APT_DEB" "$STAGE/apt" || return 1

    if [ -n "$APTITUDE_DEB" ]; then
        dpkg-deb -x "$APTITUDE_DEB" "$STAGE/aptitude" || return 1
    fi

    echo "Pacotes de referência extraídos."
    echo "Diretório: $STAGE"
    return 0
}

comparar_arquivo() {
    LOCAL="$1"
    OFICIAL="$2"

    [ -f "$LOCAL" ] || return 0
    [ -f "$OFICIAL" ] || return 0

    if ! diff -q "$LOCAL" "$OFICIAL" >/dev/null 2>&1; then
        printf '\n=== %s ===\n' "$LOCAL"
        diff -u \
            --label="LOCAL: $LOCAL" \
            --label="REFERÊNCIA: $OFICIAL" \
            "$LOCAL" "$OFICIAL" 2>/dev/null || true
    fi
}

opcao_1() {
    titulo
    echo "COMPARAÇÃO: somente diferenças"
    echo

    baixar_referencias || {
        pausar
        return
    }

    ENCONTROU=0

    for PACOTE in apt aptitude; do
        BASE="$STAGE/$PACOTE"
        [ -d "$BASE/etc" ] || continue

        while IFS= read -r OFICIAL; do
            RELATIVO="${OFICIAL#"$BASE"}"
            LOCAL="/${RELATIVO#/}"

            protegido "$LOCAL" && continue
            [ -f "$LOCAL" ] || continue

            if ! diff -q "$LOCAL" "$OFICIAL" >/dev/null 2>&1; then
                ENCONTROU=1
                comparar_arquivo "$LOCAL" "$OFICIAL"
            fi
        done < <(find "$BASE/etc" -type f 2>/dev/null)
    done

    if [ "$ENCONTROU" -eq 0 ]; then
        echo "Nenhuma diferença encontrada nos arquivos comparados."
    fi

    echo
    echo "Fim da comparação."
    pausar
}

opcao_2() {
    titulo
    echo "BACKUP DAS CONFIGURAÇÕES"
    echo

    DATA=$(date '+%Y%m%d_%H%M%S')
    ARCHIVE="$BACKUPDIR/apt-config-backup-$DATA.tar.gz"

    printf "Salvar /etc/apt e, se existir, /etc/aptitude? [s/N]: "
    read -r CONFIRMA

    case "$CONFIRMA" in
        s|S|sim|SIM|Sim) ;;
        *) echo "Operação cancelada."; pausar; return ;;
    esac

    if [ -d /etc/aptitude ]; then
        $SUDO tar -czpf "$ARCHIVE" -C / etc/apt etc/aptitude
    else
        $SUDO tar -czpf "$ARCHIVE" -C / etc/apt
    fi

    if [ "$?" -eq 0 ]; then
        $SUDO chown "$(id -u):$(id -g)" "$ARCHIVE"
        printf '%s\n' "$ARCHIVE" > "$LASTBACKUP"
        echo "Backup criado: $ARCHIVE"
    else
        echo "ERRO ao criar backup."
        rm -f "$ARCHIVE"
    fi

    pausar
}

opcao_3() {
    titulo
    echo "ATUALIZAÇÃO DAS CONFIGURAÇÕES"
    echo "As fontes de repositórios, chaves e preferências serão preservadas."
    echo

    baixar_referencias || {
        pausar
        return
    }

    echo "Arquivos que serão instalados ou atualizados:"
    CONTAGEM=0

    for PACOTE in apt aptitude; do
        BASE="$STAGE/$PACOTE"
        [ -d "$BASE/etc" ] || continue

        while IFS= read -r OFICIAL; do
            RELATIVO="${OFICIAL#"$BASE"}"
            LOCAL="/${RELATIVO#/}"

            protegido "$LOCAL" && continue

            if [ ! -f "$LOCAL" ] ||
               ! diff -q "$LOCAL" "$OFICIAL" >/dev/null 2>&1; then
                echo "$LOCAL"
                CONTAGEM=$((CONTAGEM + 1))
            fi
        done < <(find "$BASE/etc" -type f 2>/dev/null)
    done

    if [ "$CONTAGEM" -eq 0 ]; then
        echo "Nenhuma alteração necessária."
        pausar
        return
    fi

    echo
    echo "Recomendado: faça backup antes de continuar."
    printf "Digite ATUALIZAR para confirmar: "
    read -r CONFIRMA

    [ "$CONFIRMA" = "ATUALIZAR" ] || {
        echo "Operação cancelada."
        pausar
        return
    }

    ERROS=0

    for PACOTE in apt aptitude; do
        BASE="$STAGE/$PACOTE"
        [ -d "$BASE/etc" ] || continue

        while IFS= read -r OFICIAL; do
            RELATIVO="${OFICIAL#"$BASE"}"
            LOCAL="/${RELATIVO#/}"

            protegido "$LOCAL" && continue

            if [ ! -f "$LOCAL" ] ||
               ! diff -q "$LOCAL" "$OFICIAL" >/dev/null 2>&1; then

                if ! $SUDO mkdir -p "$(dirname "$LOCAL")"; then
                    echo "ERRO criando diretório: $LOCAL"
                    ERROS=$((ERROS + 1))
                    continue
                fi

                if ! $SUDO install -o root -g root -m 644 \
                    "$OFICIAL" "$LOCAL"; then
                    echo "ERRO atualizando: $LOCAL"
                    ERROS=$((ERROS + 1))
                else
                    echo "Atualizado: $LOCAL"
                fi
            fi
        done < <(find "$BASE/etc" -type f 2>/dev/null)
    done

    echo
    echo "Operação concluída. Erros: $ERROS"
    pausar
}

opcao_4() {
    titulo
    echo "RESTAURAR BACKUP"
    echo

    if [ ! -f "$LASTBACKUP" ]; then
        echo "Nenhum backup recente registrado."
        echo "Backups disponíveis:"
        find "$BACKUPDIR" -maxdepth 1 -type f -name '*.tar.gz' -print
        pausar
        return
    fi

    ARCHIVE=$(cat "$LASTBACKUP")

    if [ ! -f "$ARCHIVE" ]; then
        echo "Backup não encontrado: $ARCHIVE"
        pausar
        return
    fi

    echo "Backup selecionado: $ARCHIVE"
    printf "Digite RESTAURAR para confirmar: "
    read -r CONFIRMA

    [ "$CONFIRMA" = "RESTAURAR" ] || {
        echo "Operação cancelada."
        pausar
        return
    }

    DATA=$(date '+%Y%m%d_%H%M%S')

    if tar -tzf "$ARCHIVE" | grep -q '^etc/aptitude/'; then
        if [ -d /etc/aptitude ]; then
            $SUDO mv /etc/aptitude "/etc/aptitude.rollback-$DATA" || {
                echo "ERRO preservando /etc/aptitude."
                pausar
                return
            }
        fi
    fi

    if [ -d /etc/apt ]; then
        $SUDO mv /etc/apt "/etc/apt.rollback-$DATA" || {
            echo "ERRO preservando /etc/apt."
            pausar
            return
        }
    fi

    if $SUDO tar -xzpf "$ARCHIVE" -C /; then
        echo "Restauração concluída."
        echo "Diretórios anteriores, se existentes, foram preservados"
        echo "com o sufixo .rollback-$DATA."
    else
        echo "ERRO durante a restauração. Verifique os diretórios rollback."
    fi

    pausar
}

while true; do
    titulo
    echo "1) Comparar diferenças local x referência"
    echo "2) Fazer backup"
    echo "3) Atualizar configurações"
    echo "4) Restaurar backup"
    echo "0) Sair"
    echo
    printf "Escolha: "
    read -r OPCAO

    case "$OPCAO" in
        1) opcao_1 ;;
        2) opcao_2 ;;
        3) opcao_3 ;;
        4) opcao_4 ;;
        0) exit 0 ;;
        *) echo "Opção inválida."; pausar ;;
    esac
done
