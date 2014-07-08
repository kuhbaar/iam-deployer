#  Oracle database functions

#  sorce the oracle environment, in parameter
#+ 1: oracle_home of database installation
#+ 2: database name, used as SID
#
function dbs_source_env() {
  if ! [ -a ${1} ] ; then
    log "dbs_source_env" "ERROR: given directory doesn't exist"
  else
    ORAENV_ASK=NO
    ORACLE_SID=${2}
    set +o nounset
    . ${1}/bin/oraenv -s
    set -o nounset
    log "dbs_source_env" "environment set"
  fi
}
  
#  alter database settings
#
config_database_for_iam() {
  log "config_database_for_iam" "start"
  if [ -z ${ORACLE_SID} ] ; then
    ORACLE_SID=${dbs_sid}
  fi
  ${ORACLE_HOME}/bin/sqlplus -s / as sysdba &> /dev/null << EOF
  alter system set processes=500 scope=spfile;
  alter system set open_cursors=1500 scope=spfile;
  shutdown immediate;
  startup;
  exit;
EOF
  log "config_database_for_iam" "done"
}

#  restart database
#
restart_db() {
  if [ -z ${ORACLE_SID} ] ; then
    ORACLE_SID=${dbs_sid}
  fi
  ${ORACLE_HOME}/bin/sqlplus -s / as sysdba &>/dev/null << EOF
  whenever sqlerror exit sql.sqlcode;
  shutdown immediate;
  startup;
  exit;
EOF
}

#  set datbase to autostart
#
set_db_autostart() {
  sudo -n sed -i -e "s/${dbs_sid}:\/appl\/dbs\/product\/11.2\/db:N/${dbs_sid}:\/appl\/dbs\/product\/11.2\/db:Y/g" /etc/oratab
}

#  set ORACLE_HOME from user config
#
set_oracle_home() {
  local c=$(grep ORACLE_HOME ${_DIR}/user-config/dbs/db_install.rsp)
  if [ -n ${c} ] ; then
    export ${c}
    export PATH=${PATH}:${ORACLE_HOME}/bin
    export LD_LIBRARY_PATH=${ORACLE_HOME}/lib
    log "set_oracle_home" "ORACLE_HOME, LD_LIBRARY_PATH set"
  else
    log "set_oracle_home" "ERROR: could not set ORACLE_HOME"
  fi
}


# Oracle Database installation
#
install_db() {
  log "install_db" "start"
  if [ -a ${ORACLE_HOME}/bin/sqlplus ] ; then
    log "install_db" "skipped"
  else
    log "install_db" "installing..."
    ${s_img_db}/database/runInstaller -silent \
        -waitforcompletion \
        -ignoreSysPrereqs \
        -ignorePrereq \
        -responseFile ${_DIR}/user-config/dbs/db_install.rsp
    log "install_db" "installation done, executing root scripts..."
    log "install_db" "executing root script.."
    if ! sudo -n ${ORACLE_HOME}/root.sh ; then
      echo "ERROR: No permission, but I will continue.  Afterwards root must execute
      ${ORACLE_HOME}/root.sh"
    fi
    log "install_db" "done"
  fi
}

# Patch Opatch utility, this is patch p6880880
#
patch_opatch() {
  local _o=${ORACLE_HOME}/OPatch
  local _b=${ORACLE_HOME}/OPatch.prev
  local _skip='OPatch.*11\.2\.0\.3\.5'
  log "patch_opatch" "start"

  if ! ${ORACLE_HOME}/OPatch/opatch lsinventory | grep -q ${_skip} ; then
    [ -a ${_b} ] && rm -Rf ${_b}
    mv ${_o} ${_b}
    cp -R ${s_patches}/p6880880/OPatch $(dirname ${_o})/
    log "patch_opatch" "done"
  else
    log "patch_opatch" "skipped"
  fi
}

#  Patch the Database, extracted patch files in patch folder
#+ in 1: oracle patch number
#
patch_orahome() {
  log "patch_orahome_$1" "start"

  # check if patch has already been applied
  if ! ${ORACLE_HOME}/OPatch/opatch lsinventory | grep -q $1 ; then
    (
      log "patch_orahome_$1" "applying now..."
      cd ${s_patches}/$1
      ${ORACLE_HOME}/OPatch/opatch apply \
          -silent \
          -ocmrf ${_DIR}/lib/dbs/ocm.rsp
      log "patch_orahome_$1" "end"
    )
  else
    log "patch_orahome_$1" "already applied - skipped"
  fi
}

#  create database
#
create_database() {
  log "create_database" "start"

  # check if db already exists
  if ! grep -q ${dbs_sid} /etc/oratab ; then
    
    # new resp file, simple config does globbing in response file
    local tmp_db_rsp=/tmp/db_create.rsp
    if [ "${dbs_db_advanced}" == "true" ] ; then
      # advance config: resp file is used as is
      cp ${_DIR}/user-config/dbs/db_create_advanced.rsp ${tmp_db_rsp}
    else
      # simple config: globbing - only a few attributes are filled
      while read line ; do
        eval echo "$line" > ${tmp_db_rsp}
      done < ${_DIR}/user-config/dbs/db_create_simple.tpl
    fi

    # create db with resp file
    ${ORACLE_HOME}/bin/dbca -silent -responseFile ${tmp_db_rsp}
    log "create_database" "db created"
    log "create_database" "done"
  else
    log "create_database" "skipped"
  fi
}

# Configure database listener and networking configureation
#
run_netca() {
  log "run_netca" "start"
  if ! [ -a ${ORACLE_HOME}/network/admin/listener.ora ] ; then
    ${ORACLE_HOME}/bin/netca -silent \
        -responsefile ${_DIR}/user-config/dbs/db_netca.rsp
    log "run_netca" "done"
  else
    log "run_netca" "skipped"
  fi
}

# ------------------------------------------------------------
#
# Check for OID DB Schemas
#
check_oid_schemas() {
  local old_sid=$ORACLE_SID              # backup old SID name
  export ORACLE_SID=${DB_SERVICENAME}     # set new SID name

  ## execute SQL script (check if ODS and ODSSM schemas exist) with sqlplus
  ${ORACLE_HOME}/bin/sqlplus -s / as sysdba << EOF &>/dev/null
  whenever sqlerror exit sql.sqlcode;
  set echo off 
  set heading off
  SPOOL schema_check.sql
  select username from dba_users;
  SPOOL off
  exit;
EOF
  export ORACLE_SID=$old_sid 
}

