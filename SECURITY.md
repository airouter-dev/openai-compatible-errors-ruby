# Security policy

Do not put API keys, prompts, completions, customer payloads or production
tracebacks in issues or pull requests.

The library is safe by default in one important way: ApiError has no raw body
or headers field, and provider text is omitted unless the caller explicitly
opts in. sanitize_for_log is bounded and cycle-aware, but no redactor can
guarantee that arbitrary application data is safe to log.

Report a suspected credential leak, parser denial of service, unsafe replay
decision or release-workflow issue through a private GitHub security advisory
at:

https://github.com/airouter-dev/openai-compatible-errors-ruby/security/advisories/new

Please include a minimal synthetic reproduction, affected version and impact.
Allow time for a fix before publishing details.
