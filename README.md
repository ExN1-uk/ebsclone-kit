# ebsclone kit

Scripts that build a new Oracle E-Business Suite 12.2 application tier on a fresh Oracle Linux 8 server (the target VM), connected to a database (PDB) that already exists. Each step checks its own result and stops with the reason when something is wrong; a finished step is skipped when it is run again.

**Step-by-step guide:** https://exn1-uk.github.io/ebsclone-kit/ (fill in the settings there and it gives you one install command per server).

| Step | Server | What it does |
|---|---|---|
| `00_check_vm.sh` | target VM | read-only checks |
| `10_os_prereqs.sh` | target VM | Oracle Linux 8 prerequisites (oracle-ebs-server-R12-preinstall), apps owner, limits, inventory |
| `05_source_preclone.sh` | source apps host | optional: refreshes the clone stage, makes appsutil.zip |
| `01_check_db.sh` | database server | read-only checks |
| `20_db_prepare.sh` | database server | guaranteed restore point, datapatch if needed, holds pending requests |
| `25_db_register.sh` | database server | txkPostPDBCreationTasks and AutoConfig |
| `30_stage_apps.sh` | target VM | copies the apps files, Oracle Linux 8 check files (patch 33471111), move plan |
| `40_configure_apps.sh` | target VM | isolation from the source and production, adcfgclone (non-interactive), adcleansrccfg |
| `50_safety_gate.sh` | database server | removes network access rules, stops the mailer, clears the mail relay |
| `60_start_verify.sh` | target VM | starts the tier, checks login, Forms, node registration and managers |
| `95_reset_apps.sh` | target VM | removes the apps tier |
| `90_reset_db.sh` | database server | flashes the PDB back to the restore point |

Settings live in `/u01/ebsclone/clone.vars` (start from `clone.vars.example`); they hold names and addresses only. Passwords are asked for when needed, never echoed and never written to disk. Watch any running step with `logs.sh`.

Patch 33471111 is Oracle software and is not included: download it from My Oracle Support.

Marcques Mouton, Stor Systems
