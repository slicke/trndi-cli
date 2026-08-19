# Bash completion for trndi-cli.
# Install: copy to /usr/share/bash-completion/completions/trndi-cli
# (or source this file from ~/.bashrc). `make install-completions` does the copy.
#
# Keep the option list in step with Usage in src/trndicli.pas.

_trndi_cli()
{
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    COMPREPLY=()

    # --stats and --spark take a number of hours, --agp a number of days;
    # suggest nothing rather than flags. --profile takes an account name,
    # which a bare --profile happens to print — one per line, no backend
    # touched — so the real accounts complete.
    case $prev in
    -s|--stats|--spark|--agp)
        return
        ;;
    -p|--profile)
        COMPREPLY=($(compgen -W "$(trndi-cli --profile 2>/dev/null)" -- "$cur"))
        return
        ;;
    esac

    COMPREPLY=($(compgen -W '--check --graph --stats --spark --agp --predict --profile --setup --help' -- "$cur"))
}
complete -F _trndi_cli trndi-cli
