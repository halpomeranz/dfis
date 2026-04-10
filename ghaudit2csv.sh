#!/usr/bin/sh
# ghaudit2csv.sh -- Hal Pomeranz (hrpomeranz@gmail.com)
#    Convert GitHub audit logs exported in JSON format to CSV file
# Version: 1.0.1 - 2026-04-10
#
# Usage: cat audit_log.json | ghaudit2csv.sh >audit_log.csv
#
# Columns in output:
#  Date/Time: YYYY-MM-DD hh:mm:ss.mmm
#  Action: "pull_request.create", etc
#  Operation: "create", "modify", etc
#  Repo: Repository name, e.g. "halpomeranz/dfis"
#  Actor: GitHub username of person making request, e.g. "halpomeranz"
#  Ext Actor Name: Usually an email address like "hrpomeranz@gmail.com"
#  Actor IP: source IP of request, not present on all audit records
#  User Agent: Reported user agent on request (can be spoofed)
#  Additional Info: Other useful info, determined by record type
#
# Note that IP address collection has to be manually enabled.
# See https://docs.github.com/en/organizations/keeping-your-organization-secure/managing-security-settings-for-your-organization/displaying-ip-addresses-in-the-audit-log-for-your-organization

# Output header for CSV file
echo '"Date/Time","Action","Operation","Repo","Actor","Ext Actor Name","Actor IP","User Agent","Additional Info"'

# The jq script below looks worse than it actually is. We convert each
# line of JSON into an array which gets sent to jq's CSV output routine
# ("[yadda, yadda, yadda, ...] | @csv").
#
# There's mess in array element #1 as we convert the epoch date in the
# input records to "YYYY-MM-DD hh:mm:ss.mmm". Every other field except
# the final field are just simple JSON elements.
#
# The ugly part is outputting the final "Additional Info" field. But this
# code is just an extended "if ... then ... elsif ..." block. Each clause
# recognizes a particular record or class of records by the value in the
# ".action" field and then outputs appropriate fields from that record.
#
jq -r \
 '[(."@timestamp" / 1000 | strftime("%F %T.")) +
                                   (."@timestamp" | tostring | .[-3:]),
 .action, .operation_type, .repo, .actor,
 .external_identity_nameid, .actor_ip, .user_agent,
 if (.action | test("^workflows.(created|cancel|delete)_workflow_run$")) then
    "Run ID: \(.workflow_run_id), Name: \(.name), Head SHA: \(.head_sha), Head Branch: \(.head_branch)"
 elif .action == "workflows.rerun_workflow_run" then
    "Run ID: \(.workflow_run_id), Name: \(.name), Attempt: \(.run_attempt), Type: \(.rerun_type), Head SHA: \(.head_sha), Head Branch: \(.head_branch)"
 elif .action == "workflows.completed_workflow_run" then
    "Run ID: \(.workflow_run_id), Name: \(.name), Attempt: \(.run_attempt), Status: \(.conclusion), Head SHA: \(.head_sha), Head Branch: \(.head_branch)"
 elif .action == "workflows.prepared_workflow_job" then
    "Run ID: \(.workflow_run_id), Job Name: \(.job_name), Workflow Ref: \(.job_workflow_ref), Secrets Passed: \(.secrets_passed)"
 elif (.action | test("^code_scanning\\.alert_")) then
    "Ref: \(.ref)"
 elif (.action | test("^hook\\.")) then
    "URL: \(.config.url)"
 elif .action == "integration_installation.repositories_added" then
    "Integration: \(.integration), Repos Added: \(.repositories_added_names)"
 elif .action == "integration_installation_request.create" then
    "Integration: \(.integration), URL: \(.url)"
 elif (.action | test("^pull_request\\.(create|remove)_review_request$")) then
    "Requestor: \(.user), Reviewer: \(.reviewer), Title: \(.pull_request_title), URL: \(.pull_request_url)"
 elif ((.action | test("^pull_request\\.")) and (.actor != .user)) then
    "Requestor: \(.user), Title: \(.pull_request_title), URL: \(.pull_request_url)"
 elif (.action | test("^pull_request\\.")) then
    "Title: \(.pull_request_title), URL: \(.pull_request_url)"
 elif (.action | test("^pull_request_review\\.")) then
    "Reviewer: \(.reviewer), Title: \(.pull_request_title), URL: \(.pull_request_url)"
 elif .action == "org_credential_authorization.grant" then
    "Token ID: \(.token_id), Application: \(.application_name), Scopes: \(.token_scopes)"
 elif .action == "org_credential_authorization.deauthorize" then
    "Token ID: \(.token_id)"
 elif .action == "org_credential_authorization.revoke" then
    "Owner: \(.owner), Token ID: \(.token_id), Scopes: \(.token_scopes)"
 elif .action == "organization_role.revoke" then
    "User: \(.user), Role: \(.organization_role_name)"
 elif .action == "personal_access_token.access_granted" then
    "User: \(.user), Token ID: \(.token_id), Repos: \(.repositories), Perms: \(.permissions)"
 elif .action == "personal_access_token.access_revoked" then
    "User: \(.user), Token ID: \(.token_id), Repos: \(.repository_selection)"
 elif .action == "personal_access_token.expiration_limit_set" then
    "User: \(.user), Token ID: \(.token_id), Expires: \(.token_expiration), Old Exp: \(.old_token_expiration)"
 elif .action == "personal_access_token.expiration_limit_unset" then
    "User: \(.user), Token ID: \(.token_id), Old Exp: \(.old_token_expiration)"
 elif .action == "personal_access_token.request_created" then
    "User: \(.user), Token ID: \(.token_id), Repos: \(.repositories), Added: \(.permissions_added), Upgraded: \(.permissions_upgraded), Unchanged: \(.permissions_unchanged)"
 elif (.action | test("^personal_access_token\\.")) then
    "User: \(.user), Token ID: \(.token_id)"
 elif ((.action == "org.invite_member") and (.user != null)) then
    "User: \(.user)"
 elif ((.action == "org.invite_member") and (.invitee_email != null)) then
    "Invite Email: \(.invitee_email)"
 elif (.action | test("^(org|repo).add_member$")) then
    "User: \(.user), Perms: \(.permission)"
 elif .action == "org.update_member" then
    "User: \(.user), Old Perms: \(.old_permission), New Perms: \(.permission)"
 elif .action == "repo.update_member" then
    "User: \(.user), Old Perms: \(.old_repo_permission), New Perms: \(.new_repo_permission)"
 elif (.action | test("^(org|repo).remove_member$")) then
    "User: \(.user)"
 elif .action == "repository_invitation.create" then
    "Invitee: \(.invitee)"
 elif .action == "org.audit_log_export" then
    "Query: \(.query_phrase)"
 elif .action == "repo.rename" then
    "Old Name: \(.old_name)"
 elif .action == "repo.rename_branch" then
    "Old Branch: \(.old_branch), New Branch: \(.new_branch)"
 elif .action == "repo.update_default_branch" then
    "Old Default: \(.changes.old_default_branch), New Default: \(.changes.default_branch)"
 elif (.action | test("^repository_security_configuration\\.")) then
    "Config Name: \(.security_configuration_name)"
 elif (.action | test("^repository_vulnerability_alert\\.")) then
    "Alert ID: \(.alert_id), Alert Num: \(.alert_number)"
 elif (.action | test("^org\\.oauth_app_access_")) then
    "OAuth App: \(.oauth_application_name), URL: \(.url)"
 elif (.action | test("^(org|repo)\\.(create|update|remove)_actions_secret")) then
    "Key: \(.key)"
 elif (.action | test("^(org|repo)\\.(create|update)_integration_secret")) then
    "Integration: \(.integration), Key: \(.key)"
 elif (.action | test("^team.(add_member|remove_member|promote_maintainer)$")) then
    "User: \(.user), Team: \(.team), Team Type: \(.team_type)"
 elif (.action | test("^team.(create|add_to_organization|(add|remove)_repository)$")) then
    "Team: \(.team), Team Type: \(.team_type)"
 elif .action == "team.update_repository_permission" then
    "Team: \(.team), Old Perms: \(.old_repo_permission), New Perms: \(.new_repo_permission)"
 elif ((.action | test("^protected_branch\\.")) and (.branch != null)) then
    "Branch: \(.branch)"
 elif ((.action | test("^protected_branch\\.")) and (.branch == null)) then
    "Branch: \(.name)"
 elif (.action | test("^repository_vulnerability_alert\\.(create|reintroduce|resolve|withdraw)$")) then
    "Alert ID: \(.alert_id), Alert Num: \(.alert_number)"
 elif (.action | test("^repository_vulnerability_alert\\.auto_(dismiss|reopen)$")) then
    "Alert ID: \(.alert_id), Alert Num: \(.alert_number), Rule Name: \(.vulnerability_alert_rule_name)"
 elif (.action | test("^secret_scanning_alert\\.")) then
    "Secret Type: \(.secret_type), Display Name: \(.secret_type_display_name)"
 elif (.action | test("^required_status_check\\.")) then
    "Context: \(.context)"
 elif (.action | test("^packages\\.package_version_")) then
    "Package: \(.package)"
 elif (.action | test("^environment\\.")) then
    "Environment: \(.environment_name)"
 elif (.action | test("^public_key\\.")) then
    "Title: \(.title), Fingerprint: \(.fingerprint)"
 elif .actor != .user and .user != null then
    "User: \(.user)"
 elif .repo == null and .org != null then
    "Organization: \(.org)"
 else null end] | @csv'
