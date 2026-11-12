Captured REAL output of kubectl v1.33.3 (client Version: v1.33.3) on 2026-11-12, `kubectl create secret generic auditor-client-cert [--from-literal=...] --dry-run=client -o go-template=<T>`:
  guard template  {{if .data}}{{len .data}}{{else}}0{{end}}   empty Secret -> "0"   (no trailing newline)   Secret with one key -> "1"
  names template  {{range $k, $v := .data}}{{$k}} {{end}}      keys tls.key+tls.crt -> "tls.crt tls.key " (sorted, trailing space)   empty -> ""
Names and counts only; no Secret value. scripts/test-auditorsign.sh feeds these fixtures to its kubectl stub and, when kubectl exists, re-captures them with the REAL kubectl from the templates extracted from the RENDERED Job scripts.
