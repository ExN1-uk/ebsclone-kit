#!/bin/bash
# 50_safety_gate.sh  -  database server, as oracle. CHANGES the PDB (back end / database update).
# The PDB is a copy of another environment's data (often a restore of production). Before any apps
# service starts, remove everything that lets it reach out: network ACEs, the mailer, database links, SMTP.
. "$(dirname "$0")/lib.sh"
need_user oracle
not_prod
db_env

say "-- what the copy can reach today"
sys_sql <<SQL | tee -a "$LOG"
set lines 200 pages 100
col host for a45
col principal for a20
alter session set container=${PDB};
select host, lower_port, upper_port, principal from dba_host_aces where host not in ('*','localhost') order by 1;
select db_link, host from dba_db_links;
select component_name, component_status, startup_mode from apps.fnd_svc_components where component_type='WF_MAILER';
SQL
confirm "Remove ALL host ACEs and database links above, set the mailer to manual and stopped, and clear smtp_out_server for $PDB?" || die "gate not applied: do NOT start the apps tier"

sys_sql <<SQL | tee -a "$LOG"
whenever sqlerror exit failure
set serveroutput on
alter session set container=${PDB};
begin
  for r in (select distinct host, lower_port, upper_port, principal, privilege, grant_type from dba_host_aces where host not in ('*','localhost')) loop
    begin
      dbms_network_acl_admin.remove_host_ace(host=>r.host, lower_port=>r.lower_port, upper_port=>r.upper_port,
        ace=>xs\$ace_type(privilege_list=>xs\$name_list(r.privilege), principal_name=>r.principal, principal_type=>xs_acl.ptype_db, granted=>(r.grant_type='GRANT')));
    exception when others then null;
    end;
  end loop;
  for r in (select host, lower_port, upper_port, acl from dba_network_acls where host not in ('*','localhost') and acl is not null) loop
    begin dbms_network_acl_admin.unassign_acl(acl=>r.acl, host=>r.host, lower_port=>r.lower_port, upper_port=>r.upper_port);
    exception when others then null; end;
  end loop;
  -- database links: every one points at whatever the source talked to. Public ones are dropped directly; a
  -- private one only by its owner, so a throwaway procedure in the owner's schema drops it and is removed again.
  for r in (select owner, db_link from dba_db_links) loop
    begin
      if r.owner = 'PUBLIC' then
        execute immediate 'drop public database link "'||r.db_link||'"';
      else
        execute immediate 'create or replace procedure "'||r.owner||'".ebsclone_drop_link as begin execute immediate ''drop database link "'||r.db_link||'"''; end;';
        execute immediate 'begin "'||r.owner||'".ebsclone_drop_link; end;';
        execute immediate 'drop procedure "'||r.owner||'".ebsclone_drop_link';
      end if;
      dbms_output.put_line('dropped database link '||r.owner||'.'||r.db_link);
    exception when others then dbms_output.put_line('could not drop '||r.owner||'.'||r.db_link||': '||sqlerrm);
    end;
  end loop;
  -- UTL_MAIL/UTL_SMTP relay: the copy carries the source's PDB-level smtp_out_server (often the live
  -- Office 365 relay). Reset it for this PDB only; ORA-32010 = it was not set, which is fine.
  begin execute immediate 'alter system reset smtp_out_server scope=both';
  exception when others then if sqlcode <> -32010 then raise; end if; end;
  update apps.fnd_svc_components set startup_mode='MANUAL', component_status='STOPPED' where component_type='WF_MAILER';
  update apps.fnd_concurrent_requests set hold_flag='Y' where phase_code='P';
  commit;
end;
/
SQL
[ "${PIPESTATUS[0]}" -eq 0 ] || die "gate SQL failed"

say "-- verify"
OUT=$(sys_sql <<SQL
set heading off feedback off pages 0 lines 200
alter session set container=${PDB};
select 'ACES '||count(*) from dba_host_aces where host not in ('*','localhost');
select 'MAILER '||component_status||' '||startup_mode from apps.fnd_svc_components where component_type='WF_MAILER';
select 'UNHELD '||count(*) from apps.fnd_concurrent_requests where phase_code='P' and nvl(hold_flag,'N')<>'Y';
select 'LINK '||db_link||' '||host from dba_db_links;
select 'SMTP '||nvl(value,'(empty)') from v\$parameter where name='smtp_out_server';
SQL
)
echo "$OUT" | tee -a "$LOG"
check "no host ACEs left" bash -c "echo \"$OUT\" | grep -q '^ACES 0'"
check "mailer stopped and manual" bash -c "! echo \"$OUT\" | grep '^MAILER' | grep -vq 'STOPPED MANUAL'"
check "every pending request on hold" bash -c "echo \"$OUT\" | grep -q '^UNHELD 0'"
check "smtp_out_server empty" bash -c "echo \"$OUT\" | grep -q '^SMTP (empty)'"
check "no database links left" bash -c "! echo \"$OUT\" | grep -q '^LINK'"
gate
ok "safety gate applied. Next: 60_start_verify.sh on the VM"
