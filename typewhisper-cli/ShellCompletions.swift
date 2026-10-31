import Foundation

enum CompletionShell: String, CaseIterable {
    case bash
    case zsh
    case fish
}

/// Shell completion scripts for `typewhisper completions <shell>`.
///
/// The scripts complete commands and options without a running app. For `--engine` and
/// `--model` values they call the hidden `typewhisper __complete engines|models` command,
/// which asks the local API and prints nothing when TypeWhisper is not reachable.
enum ShellCompletions {
    static func script(for shell: CompletionShell) -> String {
        switch shell {
        case .bash: return bashScript
        case .zsh: return zshScript
        case .fish: return fishScript
        }
    }

    /// Engine IDs from a `/v1/models` response, in API order and without duplicates.
    static func engineIDs(fromModelsJSON data: Data) -> [String] {
        var seen = Set<String>()
        return modelEntries(data).compactMap { $0["engine"] as? String }.filter { seen.insert($0).inserted }
    }

    /// Model IDs from a `/v1/models` response, limited to one engine when given.
    static func modelIDs(fromModelsJSON data: Data, engine: String?) -> [String] {
        let engine = engine?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return modelEntries(data)
            .filter { engine == nil || engine?.isEmpty == true || ($0["engine"] as? String) == engine }
            .compactMap { $0["id"] as? String }
            .filter { seen.insert($0).inserted }
    }

    private static func modelEntries(_ data: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        return models
    }

    private static let bashScript = #"""
        # bash completion for typewhisper
        # Install: add  eval "$(typewhisper completions bash)"  to ~/.bashrc

        _typewhisper_dynamic() {
            local -a extra=()
            local i word
            for ((i = 1; i < COMP_CWORD; i++)); do
                word="${COMP_WORDS[i]}"
                case "$word" in
                    --dev) extra+=(--dev) ;;
                    --port|--api-token) extra+=("$word" "${COMP_WORDS[i+1]}") ;;
                    --engine) [[ "$1" == models ]] && extra+=(--engine "${COMP_WORDS[i+1]}") ;;
                esac
            done
            command "${COMP_WORDS[0]}" __complete "$1" ${extra[@]+"${extra[@]}"} 2>/dev/null
        }

        _typewhisper_files() {
            # Bash 3.2 has no compopt; an empty reply falls back to readline's file completion there.
            type compopt >/dev/null 2>&1 || return 0
            local file
            compopt -o filenames
            COMPREPLY=()
            while IFS= read -r file; do
                COMPREPLY+=("$file")
            done < <(compgen -f -- "$cur")
        }

        _typewhisper() {
            local cur="${COMP_WORDS[COMP_CWORD]}"
            local prev="${COMP_WORDS[COMP_CWORD-1]}"
            local IFS=$' \t\n'
            COMPREPLY=()

            case "$prev" in
                --port|--api-token|--language|--language-hint|--translate-to) return 0 ;;
                --task) COMPREPLY=($(compgen -W "transcribe translate" -- "$cur")); return 0 ;;
                --engine) COMPREPLY=($(compgen -W "$(_typewhisper_dynamic engines)" -- "$cur")); return 0 ;;
                --model) COMPREPLY=($(compgen -W "$(_typewhisper_dynamic models)" -- "$cur")); return 0 ;;
            esac

            local cmd="" i word
            local -a positionals=()
            for ((i = 1; i < COMP_CWORD; i++)); do
                word="${COMP_WORDS[i]}"
                case "$word" in
                    --port|--api-token|--language|--language-hint|--task|--translate-to|--engine|--model) ((i++)) ;;
                    -?*) ;;
                    *) if [[ -z "$cmd" ]]; then cmd="$word"; else positionals+=("$word"); fi ;;
                esac
            done

            local npos=${#positionals[@]}
            local opts="--port --api-token --dev --json --help --version"
            case "$cmd" in
                "")
                    if [[ "$cur" != -* ]]; then
                        COMPREPLY=($(compgen -W "transcribe status models export import audio completions" -- "$cur"))
                        return 0
                    fi
                    ;;
                transcribe)
                    opts="$opts --language --language-hint --task --translate-to --engine --model --await-download --no-corrections"
                    if [[ "$cur" != -* && $npos -eq 0 ]]; then _typewhisper_files; return 0; fi
                    ;;
                models)
                    if [[ $npos -eq 0 ]]; then
                        if [[ "$cur" != -* ]]; then COMPREPLY=($(compgen -W "list load unload delete" -- "$cur")); return 0; fi
                    else
                        case "${positionals[0]}" in
                            load|delete) opts="$opts --engine --model" ;;
                            unload) opts="$opts --engine" ;;
                        esac
                    fi
                    ;;
                export|import)
                    [[ "$cmd" == import ]] && opts="$opts --replace"
                    if [[ "$cur" != -* && $npos -eq 0 ]]; then _typewhisper_files; return 0; fi
                    ;;
                audio)
                    if [[ "$cur" != -* && $npos -eq 0 ]]; then COMPREPLY=($(compgen -W "set" -- "$cur")); return 0; fi
                    if [[ "$cur" != -* && $npos -eq 1 && "${positionals[0]}" == set ]]; then _typewhisper_files; return 0; fi
                    ;;
                completions)
                    if [[ "$cur" != -* && $npos -eq 0 ]]; then COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur")); fi
                    return 0
                    ;;
            esac

            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            fi
        }

        # Bash 3.2 (the macOS default) has no compopt, so file arguments use -o default there.
        if type compopt >/dev/null 2>&1; then
            complete -F _typewhisper typewhisper
        else
            complete -o default -F _typewhisper typewhisper
        fi

        """#

    private static let zshScript = #"""
        #compdef typewhisper
        # zsh completion for typewhisper
        # Install: add  eval "$(typewhisper completions zsh)"  to ~/.zshrc after compinit,
        # or save it as _typewhisper in a directory on your $fpath.

        _typewhisper_dynamic() {
          local -a extra
          local i
          for (( i = 2; i < CURRENT; i++ )); do
            case ${words[i]} in
              --dev) extra+=(--dev) ;;
              --port|--api-token) extra+=(${words[i]} ${(Q)words[i+1]}) ;;
              --engine) [[ $1 == models ]] && extra+=(--engine ${(Q)words[i+1]}) ;;
            esac
          done
          ${(Q)words[1]} __complete $1 $extra 2>/dev/null
        }

        _typewhisper() {
          local cur=${words[CURRENT]} prev=${words[CURRENT-1]}
          local -a ids

          case $prev in
            --port) _message 'port number'; return ;;
            --api-token) _message 'API token'; return ;;
            --language|--language-hint|--translate-to) _message 'language code'; return ;;
            --task) compadd transcribe translate; return ;;
            --engine) ids=(${(f)"$(_typewhisper_dynamic engines)"}); compadd -a ids; return ;;
            --model) ids=(${(f)"$(_typewhisper_dynamic models)"}); compadd -a ids; return ;;
          esac

          local cmd i
          local -a positionals
          for (( i = 2; i < CURRENT; i++ )); do
            case ${words[i]} in
              --port|--api-token|--language|--language-hint|--task|--translate-to|--engine|--model) (( i++ )) ;;
              -?*) ;;
              *) if [[ -z $cmd ]]; then cmd=${words[i]}; else positionals+=(${words[i]}); fi ;;
            esac
          done

          local -a opts=(
            '--port:Server port (default: auto-detect)'
            '--api-token:API bearer token (default: auto-detect)'
            '--dev:Connect to TypeWhisper Dev instance'
            '--json:Output as JSON'
            '--help:Show help'
            '--version:Show version'
          )

          case $cmd in
            '')
              if [[ $cur != -* ]]; then
                local -a commands=(
                  'transcribe:Transcribe an audio file (or - for stdin)'
                  'status:Show server status'
                  'models:List, load, unload or delete models'
                  'export:Export a settings backup as JSON'
                  'import:Import all settings from a JSON backup'
                  'audio:Show or change audio settings'
                  'completions:Print a shell completion script'
                )
                _describe -t commands 'typewhisper command' commands
                return
              fi
              ;;
            transcribe)
              opts+=(
                '--language:Source language (e.g. en, de)'
                '--language-hint:Repeatable ordered language hint'
                '--task:transcribe (default) or translate'
                '--translate-to:Target language for translation'
                '--engine:Override the engine for this request'
                '--model:Override the model for this request'
                '--await-download:Wait for the engine to restore or download its model'
                '--no-corrections:Return raw text without Dictionary Corrections'
              )
              if [[ $cur != -* && ${#positionals} -eq 0 ]]; then _files; return; fi
              ;;
            models)
              if (( ${#positionals} == 0 )); then
                if [[ $cur != -* ]]; then
                  local -a actions=(
                    'list:List available models'
                    'load:Load and select a model'
                    'unload:Unload a model, keeping its files'
                    'delete:Delete a downloaded model'
                  )
                  _describe -t actions 'models action' actions
                  return
                fi
              else
                case ${positionals[1]} in
                  load|delete) opts+=('--engine:Engine ID' '--model:Model ID') ;;
                  unload) opts+=('--engine:Engine ID') ;;
                esac
              fi
              ;;
            export|import)
              [[ $cmd == import ]] && opts+=('--replace:Overwrite items with the same name and replace hotkeys')
              if [[ $cur != -* && ${#positionals} -eq 0 ]]; then _files; return; fi
              ;;
            audio)
              if [[ $cur != -* && ${#positionals} -eq 0 ]]; then
                local -a actions=('set:Change audio settings from a JSON file (or - for stdin)')
                _describe -t actions 'audio action' actions
                return
              fi
              if [[ $cur != -* && ${#positionals} -eq 1 && ${positionals[1]} == set ]]; then _files; return; fi
              ;;
            completions)
              if [[ $cur != -* && ${#positionals} -eq 0 ]]; then compadd bash zsh fish; fi
              return
              ;;
          esac

          if [[ $cur == -* ]]; then
            _describe -t options 'option' opts
          fi
        }

        if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
          _typewhisper "$@"
        else
          compdef _typewhisper typewhisper
        fi

        """#

    private static let fishScript = #"""
        # fish completion for typewhisper
        # Install: typewhisper completions fish > ~/.config/fish/completions/typewhisper.fish

        function __typewhisper_positionals
            set -l tokens (commandline -opc)
            set -e tokens[1]
            set -l skip 0
            for token in $tokens
                if test $skip -eq 1
                    set skip 0
                    continue
                end
                switch $token
                    case --port --api-token --language --language-hint --task --translate-to --engine --model
                        set skip 1
                    case -
                        echo $token
                    case '-*'
                    case '*'
                        echo $token
                end
            end
        end

        # True when the command and positional arguments so far are exactly $argv.
        function __typewhisper_at
            set -l positionals (__typewhisper_positionals)
            test "$positionals" = "$argv"
        end

        # True when the command is one of $argv.
        function __typewhisper_cmd
            set -l positionals (__typewhisper_positionals)
            test (count $positionals) -ge 1; and contains -- $positionals[1] $argv
        end

        # True when the command is $argv[1] and its first argument is one of $argv[2..].
        function __typewhisper_sub
            set -l positionals (__typewhisper_positionals)
            test (count $positionals) -ge 2; and test $positionals[1] = $argv[1]; and contains -- $positionals[2] $argv[2..-1]
        end

        function __typewhisper_dynamic
            set -l tokens (commandline -opc)
            set -l extra
            set -l i 1
            while test $i -lt (count $tokens)
                set i (math $i + 1)
                switch $tokens[$i]
                    case --dev
                        set -a extra --dev
                    case --port --api-token
                        set -a extra $tokens[$i] $tokens[(math $i + 1)]
                    case --engine
                        if test "$argv[1]" = models
                            set -a extra --engine $tokens[(math $i + 1)]
                        end
                end
            end
            command $tokens[1] __complete $argv[1] $extra 2>/dev/null
        end

        complete -c typewhisper -f

        complete -c typewhisper -l port -x -d 'Server port (default: auto-detect)'
        complete -c typewhisper -l api-token -x -d 'API bearer token (default: auto-detect)'
        complete -c typewhisper -l dev -d 'Connect to TypeWhisper Dev instance'
        complete -c typewhisper -l json -d 'Output as JSON'
        complete -c typewhisper -s h -l help -d 'Show help'
        complete -c typewhisper -l version -d 'Show version'

        complete -c typewhisper -n '__typewhisper_at' -a transcribe -d 'Transcribe an audio file (or - for stdin)'
        complete -c typewhisper -n '__typewhisper_at' -a status -d 'Show server status'
        complete -c typewhisper -n '__typewhisper_at' -a models -d 'List, load, unload or delete models'
        complete -c typewhisper -n '__typewhisper_at' -a export -d 'Export a settings backup as JSON'
        complete -c typewhisper -n '__typewhisper_at' -a import -d 'Import all settings from a JSON backup'
        complete -c typewhisper -n '__typewhisper_at' -a audio -d 'Show or change audio settings'
        complete -c typewhisper -n '__typewhisper_at' -a completions -d 'Print a shell completion script'

        complete -c typewhisper -n '__typewhisper_at transcribe' -F
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l language -x -d 'Source language (e.g. en, de)'
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l language-hint -x -d 'Repeatable ordered language hint'
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l task -x -a 'transcribe translate' -d 'transcribe (default) or translate'
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l translate-to -x -d 'Target language for translation'
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l await-download -d 'Wait for the engine to restore or download its model'
        complete -c typewhisper -n '__typewhisper_cmd transcribe' -l no-corrections -d 'Return raw text without Dictionary Corrections'
        complete -c typewhisper -n '__typewhisper_cmd transcribe; or __typewhisper_sub models load unload delete' -l engine -x -a '(__typewhisper_dynamic engines)' -d 'Engine ID'
        complete -c typewhisper -n '__typewhisper_cmd transcribe; or __typewhisper_sub models load delete' -l model -x -a '(__typewhisper_dynamic models)' -d 'Model ID'

        complete -c typewhisper -n '__typewhisper_at models' -a list -d 'List available models'
        complete -c typewhisper -n '__typewhisper_at models' -a load -d 'Load and select a model'
        complete -c typewhisper -n '__typewhisper_at models' -a unload -d 'Unload a model, keeping its files'
        complete -c typewhisper -n '__typewhisper_at models' -a delete -d 'Delete a downloaded model'

        complete -c typewhisper -n '__typewhisper_at export; or __typewhisper_at import' -F
        complete -c typewhisper -n '__typewhisper_cmd import' -l replace -d 'Overwrite items with the same name and replace hotkeys'

        complete -c typewhisper -n '__typewhisper_at audio' -a set -d 'Change audio settings from a JSON file (or - for stdin)'
        complete -c typewhisper -n '__typewhisper_at audio set' -F

        complete -c typewhisper -n '__typewhisper_at completions' -a 'bash zsh fish'

        """#
}
