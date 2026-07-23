# Killer demo policy — config-driven via espera.yaml (input.config).
# Canonical copy: examples/test-espera/

package espera.policy

import rego.v1

default decision := {"action": "allow"}

secret_block if {
	input.action.type == "shell_command"
	input.action.reason == "secret_file_read"
}

secret_block if {
	input.action.type == "file_read"
	is_secret_path(input.action.path)
}

secret_block if {
	input.action.type == "mcp_tool_call"
	input.action.reason == "mcp_secret_file"
}

mcp_server_blocked if {
	input.action.type == "mcp_tool_call"
	input.action.server == input.config.mcp_blocked_servers[_]
}

mcp_tool_requires_approval if {
	input.action.type == "mcp_tool_call"
	mcp_tool_key == input.config.mcp_require_approval_tools[_]
}

mcp_tool_key := sprintf("%s:%s", [input.action.server, input.action.tool])

mcp_github_write_match if {
	not secret_block
	not mcp_server_blocked
	not mcp_mint_match
	input.action.type == "mcp_tool_call"
	input.action.reason == "mcp_github_write"
}

mcp_unknown_tool_match if {
	not secret_block
	not mcp_server_blocked
	not mcp_mint_match
	input.action.type == "mcp_tool_call"
	input.action.reason == "mcp_unknown_tool"
}

secret_block if {
	input.action.type in {"file_read", "file_write", "git_diff"}
	reason_has_token(input.action.reason, "secret_file")
}

shell_block if {
	not secret_block
	not mcp_server_blocked
	input.action.type == "shell_command"
	shell_reason_blocked(input.action.reason)
}

network_block if {
	not secret_block
	not shell_block
	input.action.type == "shell_command"
	input.action.reason == "network_fetch"
	input.config.block_network
}

publish_block if {
	not secret_block
	not shell_block
	not network_block
	input.action.type == "shell_command"
	input.action.reason == "package_publish"
	input.config.block_package_publish
}

db_write_block if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	input.config.block_db_writes
	db_rule_matches(input.action.reason, input.config.block_db_sql_rules[_])
}

package_check_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	input.config.require_package_check
	input.config.package_check_require_approval_on_vuln
	input.action.type in {"git_diff", "file_write", "file_read"}
	package_vuln_reason(input.action.reason)
}

redact_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	input.action.type == "file_read"
	redact_path(input.action.path)
}

redact_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	input.action.type == "shell_command"
	contains(input.action.command, "config/app.settings")
}

redact_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	input.action.type == "mcp_tool_call"
	contains(input.action.arguments_summary, "config/app.settings")
}

codeowner_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	not redact_match
	input.action.type in {"git_diff", "file_write", "file_read"}
	auth_path_match(input.action.path)
}

mint_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	input.action.type == "shell_command"
	input.action.reason == "package_publish"
	not input.config.block_package_publish
}

mcp_mint_match if {
	not secret_block
	not mcp_server_blocked
	input.action.type == "mcp_tool_call"
	input.action.server == "github"
	input.action.tool == "get_me"
}

approval_match if {
	not secret_block
	not mcp_server_blocked
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	not redact_match
	not codeowner_match
	not mint_match
	input.action.type in {"git_diff", "file_write", "file_read"}
	approval_reason_match(input.action.reason)
}

sensitive_match if {
	not secret_block
	not shell_block
	not network_block
	not publish_block
	not db_write_block
	not package_check_match
	not redact_match
	not codeowner_match
	not mint_match
	not approval_match
	input.action.type in {"git_diff", "file_write", "file_read"}
	sensitive_reason_match(input.action.reason)
}

decision := {"action": "block", "reason": "secret file read"} if {
	secret_block
}

decision := {"action": "block", "reason": "mcp server blocked"} if {
	mcp_server_blocked
}

decision := {"action": "block", "reason": "blocked shell command"} if {
	shell_block
}

decision := {"action": "block", "reason": "unapproved network egress"} if {
	network_block
}

decision := {"action": "block", "reason": "package publish not allowed"} if {
	publish_block
}

decision := {"action": "block", "reason": "database write not allowed"} if {
	db_write_block
}

decision := {
	"action": "redact",
	"reason": "semi-sensitive config read",
} if {
	redact_match
}

decision := {
	"action": "require_codeowner",
	"reason": "auth path change requires codeowner",
} if {
	codeowner_match
}

decision := {
	"action": "mint_scoped_credential",
	"scope": "npm_publish",
	"resource": "registry.npmjs.org",
	"env_var": "NPM_TOKEN",
	"ttl_secs": 300,
	"reason": "scoped publish credential",
} if {
	mint_match
}

decision := {
	"action": "mint_scoped_credential",
	"scope": "mcp_github",
	"resource": "github",
	"env_var": "GITHUB_TOKEN",
	"ttl_secs": 300,
	"reason": "scoped github mcp credential",
} if {
	mcp_mint_match
}

decision := {
	"action": "require_approval",
	"approver": "security-team",
	"reason": "mcp tool requires approval",
} if {
	mcp_tool_requires_approval
}

decision := {
	"action": "require_approval",
	"approver": "security-team",
	"reason": "mcp github write requires approval",
} if {
	mcp_github_write_match
}

decision := {
	"action": "require_approval",
	"approver": "security-team",
	"reason": "mcp unknown tool requires approval",
} if {
	mcp_unknown_tool_match
}

decision := {
	"action": "require_approval",
	"approver": package_check_approver(input.action.reason),
	"reason": "dependency change requires approval",
} if {
	package_check_match
}

decision := {
	"action": "require_approval",
	"approver": approval_approver(input.action.reason),
	"reason": approval_reason(input.action.reason),
} if {
	approval_match
}

decision := {
	"action": "allow_sensitive",
	"reason": sensitive_reason(input.action.reason),
} if {
	sensitive_match
}

shell_reason_blocked(reason) if {
	reason == input.config.block_shell_reasons[_]
}

approval_reason_match(reason) if {
	reason == input.config.approval_reasons[_]
}

sensitive_reason_match(reason) if {
	reason == input.config.sensitive_reasons[_]
}

approval_approver(reason) := input.config.approvals[reason] if {
	input.config.approvals[reason]
}

approval_approver(reason) := "security-team" if {
	not input.config.approvals[reason]
}

approval_reason(reason) := "ci/cd workflow change" if {
	reason == "ci_cd_path"
}

approval_reason(reason) := "elevated GitHub Actions permissions" if {
	reason == "github_actions_elevated_permissions"
}

approval_reason(reason) := "self-hosted runner in workflow" if {
	reason == "github_actions_self_hosted"
}

approval_reason(reason) := "third-party workflow action" if {
	reason == "github_actions_third_party_action"
}

approval_reason(reason) := "deployment environment in workflow" if {
	reason == "github_actions_deployment"
}

approval_reason(reason) := reason if {
	reason != "ci_cd_path"
	reason != "github_actions_elevated_permissions"
	reason != "github_actions_self_hosted"
	reason != "github_actions_third_party_action"
	reason != "github_actions_deployment"
}

sensitive_reason(reason) := "billing path touched" if {
	reason == "billing_path"
}

sensitive_reason(reason) := reason if {
	reason != "billing_path"
}

auth_path_match(path) if {
	startswith(path, "src/auth/")
}

redact_path(path) if {
	path == "config/app.settings"
}

is_secret_path(path) if {
	path == ".env"
}

is_secret_path(path) if {
	startswith(path, ".env.")
}

is_secret_path(path) if {
	contains(path, "/.env")
}

is_secret_path(path) if {
	endswith(path, ".pem")
}

is_secret_path(path) if {
	endswith(path, ".key")
}

# Scanner-enriched reasons are colon-joined (e.g. shell_script:secret_file:gitleaks:...).
reason_has_token(reason, token) if {
	reason == token
}

reason_has_token(reason, token) if {
	startswith(reason, concat("", [token, ":"]))
}

reason_has_token(reason, token) if {
	endswith(reason, concat("", [":", token]))
}

reason_has_token(reason, token) if {
	contains(reason, concat("", [":", token, ":"]))
}

db_rule_matches(reason, rule) if {
	reason_has_token(reason, rule)
}

db_rule_matches(reason, rule) if {
	reason_has_token(reason, concat("sqlparser:", rule))
}

package_vuln_reason(reason) if {
	reason_has_token(reason, "osv")
}

package_vuln_reason(reason) if {
	reason_has_token(reason, "trivy")
}

package_check_approver(reason) := input.config.approvals["dependency_change"] if {
	input.config.approvals["dependency_change"]
}

package_check_approver(reason) := "security-team" if {
	not input.config.approvals["dependency_change"]
}
