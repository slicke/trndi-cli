# Bash completion for trndi-cli.
# Install: copy to /usr/share/bash-completion/completions/trndi-cli
# (or source this file from ~/.bashrc). `make install-completions` does the copy.
#
# Keep the option list in step with Usage in src/trndicli.pp.

_trndi_cli()
{
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    COMPREPLY=()

    # --stats, --spark and --csv take a number of hours, --agp a number of
    # days, --remind a number of minutes; suggest nothing rather than flags. --profile takes an account name,
    # which a bare --profile happens to print — one per line, no backend
    # touched — so the real accounts complete.
    case $prev in
    -s|--stats|--spark|--agp|--csv|--remind)
        return
        ;;
    --on-reading|--on-low|--on-high|--on-ok|--on-stale)
        # A shell command: let the default completion offer commands.
        COMPREPLY=($(compgen -c -- "$cur"))
        return
        ;;
    -p|--profile)
        COMPREPLY=($(compgen -W "$(trndi-cli --profile 2>/dev/null)" -- "$cur"))
        return
        ;;
    -u|--unit)
        COMPREPLY=($(compgen -W 'mmol mgdl' -- "$cur"))
        return
        ;;
    esac

    COMPREPLY=($(compgen -W '--check --graph --stats --spark --agp --csv --device --watch --on-reading --on-low --on-high --on-ok --on-stale --remind --predict --unit --profile --setup --help --version' -- "$cur"))
}
complete -F _trndi_cli trndi-cli
