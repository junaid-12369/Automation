/*
 =============================================================================
 Multi-server automated deployment pipeline
 =============================================================================
 Targets:
   APP_SERVER (172.31.3.85)  -> install_apache_httpd.sh, opensearch_dashboards_install.sh
   DI_SERVER  (172.31.10.254)-> install_nifi.sh
   DB1_SERVER (172.31.6.212) -> pg_install_master.sh, opensearch_install.sh
   DB2_SERVER (172.31.11.87) -> druid_install.sh

 All five scripts are 100% interactive (bash `read` prompts). Since Jenkins
 can't type into a TTY, every prompt's answer is pre-built (in the exact
 order the script asks for it) from build parameters below and piped into
 the script over SSH via stdin (a heredoc). If you ever edit a script and
 add/remove/reorder a `read`/`ask` call, the matching stdin block here must
 be updated to match, or the wrong answer will land on the wrong prompt.

 Assumptions:
   - Passwordless sudo is configured for SSH_USER on all 4 targets
     (typical default for ubuntu/ec2-user AMIs). If not, sudo will hang
     waiting for a TTY password and the stage will time out.
   - The 5 scripts live in this Jenkins repo under ./scripts/
   - An SSH private-key credential is stored in Jenkins with the ID given
     in SSH_CREDENTIALS_ID
   - This job is configured as "Pipeline script from SCM" pointing at the
     repo containing ./scripts/ - `checkout scm` will fail otherwise.

 v2 fixes applied (found by reading the actual install scripts line-by-line):
   1. druid_install.sh persists all answers to /etc/druid-install/state.env
      on the target server and silently REUSES them on every later run,
      ignoring new parameters, unless invoked with --reconfigure. Added
      DRUID_RECONFIGURE param + a pre-flight stage that passes the flag.
   2. druid_install.sh's prompt_volume() loops forever re-reading stdin if
      /opt/<volume> doesn't already exist, desyncing every answer after it.
      Added a pre-flight stage that mkdir -p's the volume dir first.
   3. install_nifi.sh's prompt_disk() hard-dies (does not create the dir)
      if the base path doesn't already exist. Added a pre-flight stage that
      mkdir -p's it first.
   4. opensearch_dashboards_install.sh can only auto-find OpenSearch's
      root-ca.pem on its OWN filesystem - but Dashboards runs on APP_SERVER
      while the CA lives on DB1_SERVER. Added a stage that copies the CA
      from DB1_SERVER to APP_SERVER (via the Jenkins agent) before running
      Dashboards, and passes --opensearch-root-ca. Failure to fetch it is
      non-fatal - the script itself falls back to unverified TLS with a
      warning, same as before this fix.
   5. Removed the separate 'opensearch-admin-password' Jenkins credential
      requirement (it hard-failed the whole build if that credential ID
      didn't exist, even when OS_ADMIN_PASSWORD was intentionally left
      blank). The admin password is now resolved ONCE from OS_ADMIN_PASSWORD
      (falling back to the script's own default) and reused consistently
      for both the OpenSearch stage and the Dashboards stage. Also switched
      from `sudo -n VAR=value bash script` (unreliable - depends on sudoers
      env_keep/setenv policy) to `sudo -n env VAR=value bash script`, which
      reliably sets the variable regardless of sudoers env settings.
 =============================================================================
*/

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 3, unit: 'HOURS')
    }

    parameters {
        string(name: 'SSH_USER', defaultValue: 'ubuntu', description: 'OS login user on all 4 target servers')
        string(name: 'SSH_CREDENTIALS_ID', defaultValue: 'aws-ubuntu-ssh', description: 'Jenkins credential ID of the SSH private key (SSH Username with private key)')
        string(name: 'APP_SERVER', defaultValue: '172.31.3.85', description: 'Apache httpd + OpenSearch Dashboards')
        string(name: 'DI_SERVER', defaultValue: '172.31.10.254', description: 'NiFi standalone')
        string(name: 'DB1_SERVER', defaultValue: '172.31.6.212', description: 'PostgreSQL + OpenSearch standalone')
        string(name: 'DB2_SERVER', defaultValue: '172.31.11.87', description: 'Druid standalone')

        booleanParam(name: 'DEPLOY_POSTGRES', defaultValue: true, description: 'Run pg_install_master.sh on DB1_SERVER')
        booleanParam(name: 'DEPLOY_OPENSEARCH', defaultValue: true, description: 'Run opensearch_install.sh on DB1_SERVER')
        booleanParam(name: 'DEPLOY_DRUID', defaultValue: true, description: 'Run druid_install.sh on DB2_SERVER')
        booleanParam(name: 'DEPLOY_NIFI', defaultValue: true, description: 'Run install_nifi.sh on DI_SERVER')
        booleanParam(name: 'DEPLOY_APACHE', defaultValue: true, description: 'Run install_apache_httpd.sh on APP_SERVER')
        booleanParam(name: 'DEPLOY_DASHBOARDS', defaultValue: true, description: 'Run opensearch_dashboards_install.sh on APP_SERVER (needs OpenSearch already up on DB1_SERVER)')

        string(name: 'PG_VERSION', defaultValue: '17.6', description: 'PostgreSQL version to build')
        string(name: 'PG_BASE_DIR', defaultValue: '/data', description: 'Base install path on DB1_SERVER (never /, /etc, /home, etc.)')
        string(name: 'PG_PORT', defaultValue: '5432', description: 'PostgreSQL port')
        string(name: 'PG_SERVICE_USER', defaultValue: 'postgres', description: 'OS user PostgreSQL runs as')
        string(name: 'PG_MASTER_IP', defaultValue: '172.31.6.212', description: 'listen_addresses IP (usually = DB1_SERVER)')
        string(name: 'PG_REPLICA_IPS', defaultValue: '', description: 'Comma-separated replica IPs to pre-authorize (leave blank - standalone, no replica this run)')
        booleanParam(name: 'PG_OPEN_CLIENT_ACCESS', defaultValue: false, description: 'Allow app clients from 0.0.0.0/0 with password auth')
        string(name: 'PG_APP_DB', defaultValue: 'appdb', description: 'Initial application database name')

        string(name: 'OS_BASE_DIR', defaultValue: '/data/opensearch', description: 'Base disk/dir on DB1_SERVER (do NOT use / — see prior disk-space incident)')
        string(name: 'OS_CLUSTER_NAME', defaultValue: 'dev-01', description: 'OpenSearch cluster name')
        password(name: 'OS_ADMIN_PASSWORD', defaultValue: '', description: 'Initial admin password (leave blank to use the script default EdxiP@ssword! — change this in production). Used for BOTH the OpenSearch stage and the Dashboards stage, so they always agree.')

        string(name: 'OSD_BASE_DIR', defaultValue: '/data/opensearch-dashboards', description: 'Base disk/dir on APP_SERVER')
        string(name: 'OSD_OS_HOST', defaultValue: '172.31.6.212', description: 'OpenSearch host Dashboards connects to (= DB1_SERVER)')
        string(name: 'OSD_OS_PORT', defaultValue: '9200', description: 'OpenSearch HTTP port')
        string(name: 'OSD_OS_USER', defaultValue: 'admin', description: 'OpenSearch admin username')
        string(name: 'OSD_BIND_HOST', defaultValue: '0.0.0.0', description: 'Address Dashboards listens on')

        string(name: 'DRUID_VOLUME_NAME', defaultValue: 'ausiytic', description: "Volume name under /opt on DB2_SERVER, or 'root' for the root volume")
        booleanParam(name: 'DRUID_RECONFIGURE', defaultValue: false, description: 'Pass --reconfigure to druid_install.sh. REQUIRED if this server was ever installed before with this script and you want to change ANY Druid setting below — otherwise the script silently reuses its saved /etc/druid-install/state.env and ignores every parameter here.')
        booleanParam(name: 'DRUID_USE_POSTGRES', defaultValue: false, description: 'Use the PostgreSQL master above as Druid metadata store instead of embedded Derby')
        string(name: 'DRUID_PG_PORT', defaultValue: '5432', description: 'Only used if DRUID_USE_POSTGRES is true')
        string(name: 'DRUID_PG_DBNAME', defaultValue: 'druid', description: 'Only used if DRUID_USE_POSTGRES is true')
        string(name: 'DRUID_PG_USER', defaultValue: 'druid', description: 'Only used if DRUID_USE_POSTGRES is true')
        string(name: 'DRUID_PG_PASSWORD', defaultValue: '', description: 'Only used if DRUID_USE_POSTGRES is true')
        booleanParam(name: 'DRUID_USE_AZURE', defaultValue: false, description: 'Use Azure Blob deep storage instead of local disk')
        string(name: 'DRUID_AZURE_ACCOUNT', defaultValue: '', description: 'Only used if DRUID_USE_AZURE is true')
        string(name: 'DRUID_AZURE_CONTAINER', defaultValue: 'druid', description: 'Only used if DRUID_USE_AZURE is true')
        string(name: 'DRUID_AZURE_KEY', defaultValue: '', description: 'Only used if DRUID_USE_AZURE is true')
        string(name: 'DRUID_ADMIN_PASSWORD', defaultValue: '', description: 'Blank = script auto-generates a random one')
        string(name: 'DRUID_INTERNAL_PASSWORD', defaultValue: '', description: 'Blank = script auto-generates a random one')

        string(name: 'NIFI_BASE_DIR', defaultValue: '/opt/ausiytic', description: "Base path on DI_SERVER, or / for root volume")
        string(name: 'NIFI_ADMIN_USER', defaultValue: 'admin', description: 'NiFi UI login username')
        string(name: 'NIFI_ADMIN_PASSWORD', defaultValue: '', description: 'NiFi UI login password, min 12 chars (REQUIRED — no safe default)')
        choice(name: 'NIFI_PROXY_CHOICE', choices: ['2', '1', '3', '4'], description: 'nifi.web.proxy.host source: 1=Public IP 2=Private IP(default, intra-VPC) 3=Both 4=Custom hostname')
        string(name: 'NIFI_CUSTOM_HOST', defaultValue: '', description: 'Only used if NIFI_PROXY_CHOICE=4')

        string(name: 'HTTPD_BASE_DIR', defaultValue: '/opt/ausiytic', description: 'Base install directory on APP_SERVER')
    }

    environment {
        SCRIPTS_DIR = 'scripts'
    }

    stages {

        stage('Validate required secrets') {
            steps {
                script {
                    if (params.DEPLOY_NIFI && params.NIFI_ADMIN_PASSWORD.trim().length() < 12) {
                        error "NIFI_ADMIN_PASSWORD must be at least 12 characters — the script itself enforces this and will hang re-prompting otherwise."
                    }
                    if (params.DEPLOY_DRUID && params.DRUID_USE_POSTGRES && !params.DRUID_PG_PASSWORD?.trim()) {
                        error "DRUID_PG_PASSWORD is required when DRUID_USE_POSTGRES is true."
                    }
                    if (params.DEPLOY_DRUID && params.DRUID_USE_AZURE && (!params.DRUID_AZURE_ACCOUNT?.trim() || !params.DRUID_AZURE_KEY?.trim())) {
                        error "DRUID_AZURE_ACCOUNT and DRUID_AZURE_KEY are required when DRUID_USE_AZURE is true."
                    }
                    if (params.DEPLOY_DASHBOARDS && !params.DEPLOY_OPENSEARCH) {
                        echo "WARNING: DEPLOY_DASHBOARDS is true but DEPLOY_OPENSEARCH is false this run. Dashboards' pre-flight check will fail unless OpenSearch is ALREADY up and reachable on DB1_SERVER."
                    }

                    // Resolved once, used consistently by both the OpenSearch stage
                    // and the Dashboards stage, instead of relying on a separate
                    // Jenkins credential (see v2 fix #5 in the header comment).
                    // OS_ADMIN_PASSWORD is a password-type parameter, so Jenkins hands it
                    // back as a hudson.util.Secret object, not a plain String - Secret has
                    // no .trim() method, so it must be converted to a String first.
                    def osAdminPasswordPlain = params.OS_ADMIN_PASSWORD?.toString()
                    RESOLVED_OS_ADMIN_PASSWORD = osAdminPasswordPlain?.trim() ?: 'EdxiP@ssword!'
                }
            }
        }

        stage('Checkout') {
            steps {
                checkout scm
                sh "chmod +x ${SCRIPTS_DIR}/*.sh"
            }
        }

        stage('DB1: PostgreSQL master') {
            when { expression { params.DEPLOY_POSTGRES } }
            steps {
                script {
                    // Order of reads in pg_install_master.sh:
                    // PG_VERSION -> BASE_DIR -> PG_PORT -> SERVICE_USER -> MASTER_IP
                    // -> REPLICA_IPS_RAW -> OPEN_CLIENT_ACCESS -> APP_DB
                    def answers = [
                        params.PG_VERSION,
                        params.PG_BASE_DIR,
                        params.PG_PORT,
                        params.PG_SERVICE_USER,
                        params.PG_MASTER_IP,
                        params.PG_REPLICA_IPS,
                        (params.PG_OPEN_CLIENT_ACCESS ? 'y' : 'N'),
                        params.PG_APP_DB
                    ].join('\n') + '\n'
                    runRemoteScript(params.DB1_SERVER, 'pg_install_master.sh', answers)
                }
            }
        }

        stage('DB1: OpenSearch') {
            when { expression { params.DEPLOY_OPENSEARCH } }
            steps {
                script {
                    // opensearch_install.sh supports --base-dir / --cluster-name flags,
                    // which skip those two prompts entirely. The final
                    // "Confirm and continue? [Y/n]" prompt still always fires.
                    //
                    // Env var is passed via `sudo -n env VAR=value bash script` rather
                    // than `sudo -n VAR=value bash script` — the latter's propagation
                    // depends on the sudoers env_keep/setenv policy and can silently
                    // drop the variable; `env` sets it unconditionally for the process
                    // it execs (see v2 fix #5 in the header comment).
                    def flags = "--base-dir '${params.OS_BASE_DIR}' --cluster-name '${params.OS_CLUSTER_NAME}'"
                    def envPrefix = "env OPENSEARCH_INITIAL_ADMIN_PASSWORD='${RESOLVED_OS_ADMIN_PASSWORD}' "
                    def answers = "Y\n"
                    runRemoteScript(params.DB1_SERVER, 'opensearch_install.sh', answers, flags, envPrefix)
                }
            }
        }

        stage('DB2: Pre-flight - ensure Druid volume directory exists') {
            when { expression { params.DEPLOY_DRUID && params.DRUID_VOLUME_NAME?.trim() && params.DRUID_VOLUME_NAME.trim() != 'root' } }
            steps {
                script {
                    // druid_install.sh's prompt_volume() loops forever re-reading stdin
                    // if /opt/<volume> doesn't already exist as a directory, which
                    // desyncs every answer piped in after it (see v2 fix #2).
                    def volDir = "/opt/${params.DRUID_VOLUME_NAME.trim()}"
                    sshRunCommand(params.DB2_SERVER, "sudo -n mkdir -p '${volDir}'")
                }
            }
        }

        stage('DB2: Druid') {
            when { expression { params.DEPLOY_DRUID } }
            steps {
                script {
                    // Order of reads in druid_install.sh (only asked on a fresh
                    // state.env, i.e. first run or --reconfigure):
                    // prompt_volume: VOLUME_NAME_RAW
                    // prompt_druid_config:
                    //   PostgreSQL host (blank = skip -> Derby)
                    //     [if non-blank: port, dbname, user, password]
                    //   Azure storage account (blank = skip -> local disk)
                    //     [if non-blank: container, key]
                    //   admin password (blank = auto-generate)
                    //   internal client password (blank = auto-generate)
                    //
                    // NOTE: these prompts (and this stdin block) are SKIPPED by the
                    // script entirely if it already has a saved state.env from a
                    // prior run on this server, UNLESS --reconfigure is passed (see
                    // DRUID_RECONFIGURE param / v2 fix #1). The stdin below is inert
                    // but harmless in that case.
                    def lines = [params.DRUID_VOLUME_NAME]
                    if (params.DRUID_USE_POSTGRES) {
                        lines += [params.DB1_SERVER, params.DRUID_PG_PORT, params.DRUID_PG_DBNAME, params.DRUID_PG_USER, params.DRUID_PG_PASSWORD]
                    } else {
                        lines += ['']
                    }
                    if (params.DRUID_USE_AZURE) {
                        lines += [params.DRUID_AZURE_ACCOUNT, params.DRUID_AZURE_CONTAINER, params.DRUID_AZURE_KEY]
                    } else {
                        lines += ['']
                    }
                    lines += [params.DRUID_ADMIN_PASSWORD, params.DRUID_INTERNAL_PASSWORD]
                    def answers = lines.join('\n') + '\n'
                    def extraArgs = params.DRUID_RECONFIGURE ? '--reconfigure' : ''
                    runRemoteScript(params.DB2_SERVER, 'druid_install.sh', answers, extraArgs)
                }
            }
        }

        stage('DI: Pre-flight - ensure NiFi base directory exists') {
            when { expression { params.DEPLOY_NIFI && params.NIFI_BASE_DIR?.trim() && params.NIFI_BASE_DIR.trim() != '/' } }
            steps {
                script {
                    // install_nifi.sh's prompt_disk() hard-dies immediately if the
                    // path doesn't already exist (it never creates it) - see v2 fix #3.
                    sshRunCommand(params.DI_SERVER, "sudo -n mkdir -p '${params.NIFI_BASE_DIR.trim()}'")
                }
            }
        }

        stage('DI: NiFi') {
            when { expression { params.DEPLOY_NIFI } }
            steps {
                script {
                    // Order of reads in install_nifi.sh:
                    // prompt_disk: DISK_MOUNT
                    // prompt_credentials: NIFI_ADMIN_USER -> NIFI_ADMIN_PASS -> confirm
                    // prompt_proxy_host: choice[1-4] -> (custom_host only if 4)
                    def lines = [
                        params.NIFI_BASE_DIR,
                        params.NIFI_ADMIN_USER,
                        params.NIFI_ADMIN_PASSWORD,
                        params.NIFI_ADMIN_PASSWORD,
                        params.NIFI_PROXY_CHOICE
                    ]
                    if (params.NIFI_PROXY_CHOICE == '4') {
                        lines += [params.NIFI_CUSTOM_HOST]
                    }
                    def answers = lines.join('\n') + '\n'
                    runRemoteScript(params.DI_SERVER, 'install_nifi.sh', answers)
                }
            }
        }

        stage('APP: Apache httpd') {
            when { expression { params.DEPLOY_APACHE } }
            steps {
                script {
                    // Order of reads in install_apache_httpd.sh: BASE_DIR -> CONFIRM[y/N]
                    def answers = "${params.HTTPD_BASE_DIR}\ny\n"
                    runRemoteScript(params.APP_SERVER, 'install_apache_httpd.sh', answers)
                }
            }
        }

        stage('APP: Fetch OpenSearch root CA for Dashboards TLS trust') {
            when { expression { params.DEPLOY_DASHBOARDS } }
            steps {
                script {
                    // opensearch_dashboards_install.sh can only auto-discover the CA
                    // on its OWN filesystem, but Dashboards runs on APP_SERVER while
                    // the CA was generated on DB1_SERVER (see v2 fix #4). Copy it
                    // across via the Jenkins agent. Non-fatal if it's not there yet
                    // (e.g. OpenSearch was installed by an older run of this pipeline,
                    // or on a schedule where DEPLOY_OPENSEARCH is false this time) -
                    // the Dashboards script itself just falls back to unverified TLS
                    // with a warning in that case, same as before this fix.
                    def remoteCaPath = "${params.OS_BASE_DIR}/apps/opensearch/binaries/config/root-ca.pem"
                    ROOT_CA_FETCHED = fetchRemoteFileThenPush(
                        params.DB1_SERVER, remoteCaPath,
                        params.APP_SERVER, '/tmp/opensearch-root-ca.pem'
                    )
                    if (!ROOT_CA_FETCHED) {
                        echo "WARNING: could not fetch OpenSearch's root-ca.pem from DB1_SERVER (${remoteCaPath}). Dashboards will fall back to unverified TLS (opensearch.ssl.verificationMode: none)."
                    }
                }
            }
        }

        stage('APP: OpenSearch Dashboards') {
            when { expression { params.DEPLOY_DASHBOARDS } }
            steps {
                script {
                    // All connection details are passed as flags, so step_prompt_inputs()
                    // skips straight to its summary + "Confirm and continue? [Y/n]" prompt,
                    // which is the ONLY thing left on stdin.
                    def flags = "--base-dir '${params.OSD_BASE_DIR}' " +
                                "--opensearch-host '${params.OSD_OS_HOST}' " +
                                "--opensearch-port '${params.OSD_OS_PORT}' " +
                                "--opensearch-user '${params.OSD_OS_USER}' " +
                                "--opensearch-password '${RESOLVED_OS_ADMIN_PASSWORD}' " +
                                "--bind-host '${params.OSD_BIND_HOST}'"
                    if (ROOT_CA_FETCHED) {
                        flags += " --opensearch-root-ca '/tmp/opensearch-root-ca.pem'"
                    }
                    def answers = "Y\n"
                    runRemoteScript(params.APP_SERVER, 'opensearch_dashboards_install.sh', answers, flags)
                }
            }
        }
    }

    post {
        always {
            echo 'Deployment run finished — see per-stage logs above for each server.'
        }
    }
}

// Set by the "Validate required secrets" and "APP: Fetch OpenSearch root CA"
// stages, read by later stages. Declared at script scope (outside pipeline{})
// so the same value persists across stages.
def RESOLVED_OS_ADMIN_PASSWORD = null
def ROOT_CA_FETCHED = false

// -----------------------------------------------------------------------
// Copies a script to the target host and runs it as root with the given
// answers piped in over stdin, inside an sshagent session so the private
// key never touches disk on the Jenkins agent.
// -----------------------------------------------------------------------
def runRemoteScript(String host,
                    String scriptName,
                    String stdinAnswers,
                    String extraFlags = '',
                    String remoteEnvPrefix = '') {

    withCredentials([
        sshUserPrivateKey(
            credentialsId: params.SSH_CREDENTIALS_ID,
            keyFileVariable: 'SSH_KEY',
            usernameVariable: 'SSH_USER_CRED'
        )
    ]) {

        def sshOpts = '-o StrictHostKeyChecking=no -o ConnectTimeout=15'

        sh """
            scp -i "\$SSH_KEY" ${sshOpts} \
            ${env.SCRIPTS_DIR}/${scriptName} \
            ${params.SSH_USER}@${host}:/tmp/${scriptName}
        """

        sh """
            ssh -i "\$SSH_KEY" ${sshOpts} \
            ${params.SSH_USER}@${host} \
            'chmod +x /tmp/${scriptName}'
        """

        writeFile(
            file: "answers-${scriptName}.txt",
            text: stdinAnswers
        )

        sh """
            ssh -i "\$SSH_KEY" ${sshOpts} \
            ${params.SSH_USER}@${host} \
            'sudo -n ${remoteEnvPrefix}bash /tmp/${scriptName} ${extraFlags}' \
            < answers-${scriptName}.txt
        """
    }
}

// -----------------------------------------------------------------------
// Runs a single one-off command on a target host over SSH (used for the
// pre-flight mkdir checks). Not for interactive scripts - no stdin piping.
// -----------------------------------------------------------------------
def sshRunCommand(String host, String remoteCommand) {
    withCredentials([
        sshUserPrivateKey(
            credentialsId: params.SSH_CREDENTIALS_ID,
            keyFileVariable: 'SSH_KEY',
            usernameVariable: 'SSH_USER_CRED'
        )
    ]) {
        def sshOpts = '-o StrictHostKeyChecking=no -o ConnectTimeout=15'
        sh """
            ssh -i "\$SSH_KEY" ${sshOpts} \
            ${params.SSH_USER}@${host} \
            '${remoteCommand}'
        """
    }
}

// -----------------------------------------------------------------------
// Copies a file from srcHost down to the Jenkins agent workspace, then
// pushes it up to dstHost. Used to move OpenSearch's root-ca.pem from
// DB1_SERVER to APP_SERVER since the two servers can't scp to each other
// directly (no SSH trust between target hosts, only between the agent and
// each host). Returns true on success, false (non-fatal) if the source
// file doesn't exist or the copy fails for any reason.
// -----------------------------------------------------------------------
def fetchRemoteFileThenPush(String srcHost, String srcPath, String dstHost, String dstPath) {
    def localTmp = "fetched-${System.currentTimeMillis()}.tmp"
    try {
        withCredentials([
            sshUserPrivateKey(
                credentialsId: params.SSH_CREDENTIALS_ID,
                keyFileVariable: 'SSH_KEY',
                usernameVariable: 'SSH_USER_CRED'
            )
        ]) {
            def sshOpts = '-o StrictHostKeyChecking=no -o ConnectTimeout=15'

            def rc = sh(
                script: """
                    scp -i "\$SSH_KEY" ${sshOpts} \
                    ${params.SSH_USER}@${srcHost}:${srcPath} \
                    ${localTmp}
                """,
                returnStatus: true
            )
            if (rc != 0) {
                echo "Could not fetch ${srcPath} from ${srcHost} (exit ${rc}) - continuing without it."
                return false
            }

            sh """
                scp -i "\$SSH_KEY" ${sshOpts} \
                ${localTmp} \
                ${params.SSH_USER}@${dstHost}:${dstPath}
            """
        }
        return true
    } catch (Exception e) {
        echo "Error copying ${srcPath} from ${srcHost} to ${dstHost}:${dstPath} - continuing without it. (${e.message})"
        return false
    } finally {
        sh "rm -f ${localTmp}"
    }
}

