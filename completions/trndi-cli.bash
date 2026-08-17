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
    # suggest nothing rather than flags.
    case $prev in
    -s|--stats|--spark|--agp)
        return
        ;;
    esac

    COMPREPLY=($(compgen -W '--check --graph --stats --spark --agp --predict --setup --help' -- "$cur"))
}
complete -F _trndi_cli trndi-cli
