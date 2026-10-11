/*
 =============================================================================
 Reusable multi-server deployment pipeline  (v5 - config driven + script prompts as parameters)
 =============================================================================
 HOW THIS WORKS
   Everything project-specific lives in ONE place: projectConfig() below
   (servers + a list of "tasks"). The pipeline itself never changes between
   projects. A task = "run script X on host Y with these inputs".

   - Tasks have a `wave` number. Waves run in ascending order (use them for
     dependencies: DB before app, Spark master before Spark workers, ...).
   - Inside a wave, tasks on DIFFERENT hosts run in parallel; tasks on the
     SAME host always run one after another (avoids apt/dpkg lock clashes).
   - N workers? Just add hosts to a list (see AIRFLOW_WORKER_HOSTS /
     SPARK_WORKER_HOSTS) - tasks are generated with a for-loop.

 SCRIPT PROMPTS = BUILD PARAMETERS  (new in v5)
   Interactive scripts (pg, httpd, nifi, druid, dashboards, kafka, polaris, chrome)
   ask questions when run by hand. Jenkins cannot stop mid-run and ask, so every
   question is a build parameter on the "Build with Parameters" page (with the same
   default you would normally type). The pipeline pipes those values to the script.
   Passwords are NOT form fields: they stay Jenkins "Secret text" credentials.
   The form shows every field; fields of services you do not deploy are ignored.
   After changing the parameters block: commit, click "Build Now" once, then reopen
   "Build with Parameters" (Jenkins only reads new parameters after a run).

 OPENSEARCH  (opensearch_install.sh - standalone AND cluster)
   - ONE opensearch host  => STANDALONE single node.
   - TWO OR MORE hosts    => CLUSTER. Host order = node order (os-node-1, os-node-2, ...).
       * the FIRST host runs in wave 1: it creates the CA, the passwords and one
         certificate bundle per node
       * Jenkins then copies each peer's bundle from the first node to the peer's /tmp
         (the nodes never need SSH access to each other), and the other nodes install
         in wave 2 (in parallel); the LAST node waits until all nodes have joined
       * Dashboards runs after the cluster is complete (wave 3 for a cluster, wave 2 standalone)
   - Hosts come from SERVERS (opensearch = ...), the OPENSEARCH_HOSTS parameter, or the
     default in projectConfig(). Hosts must be IPv4 addresses (they go into the TLS certificates).
   - The admin password is the Jenkins credential OS_CRED; the other passwords
     (kibanaserver, readuser, writeuser) are generated and saved in
     <OS_ROOT>/opensearch_credentials.txt on each node. They are masked in the build log.
   - Tune per node with OVERRIDES, e.g.  opensearch-2.HEAP_SIZE=1536m
                                         opensearch-3.NODE_ROLES=data,ingest
                                         CLUSTER_MANAGER_IPS=10.0.1.21,10.0.1.22,10.0.1.23

 PLACING SERVICES ON SERVERS  (the build parameter SERVERS)
   Give the pipeline your servers and say which services each one gets - any
   service on any server, any number of servers, several services per server:

       10.0.1.21 = pg, opensearch
       10.0.1.22 = airflow-control, kafka, opensearch
       10.0.1.23 = airflow-worker, spark-worker, chrome, opensearch
       10.0.1.24 = airflow-worker, spark-worker
       10.0.1.25 = spark-master, polaris

   When SERVERS is filled in, EXACTLY the listed services run, on exactly those
   hosts (enabled flags are ignored). Services that may go on many servers:
   opensearch, airflow-worker, spark-worker, kafka, chrome. All others go on ONE server.
   Service names: see knownServices() near the bottom. Several services on the
   same host install one after another; different hosts install in parallel.
   Values for things NOT placed this run (e.g. the Airflow control IP when you
   only add a worker, or an existing Redis) come from the defaults in
   projectConfig() or from OVERRIDES (e.g. REDIS_HOST=10.0.1.30).
   Leave SERVERS blank to use the per-role parameters / defaults instead.

 TWO TASK MODES
   mode:'env'   (default) Script supports AUTOMATED=1 + env vars
                (opensearch_install.sh, airflow_cluster_*.sh, spark_install.sh,
                spark_standalone_install.sh). All of task.env + credentials are exported to the script.
   mode:'stdin' Legacy interactive scripts (pg_install_master.sh, druid, nifi,
                httpd, opensearch dashboards). Answers are piped in, in the order the
                script asks. Use {{VAR}} tokens to pull values from task.env /
                credentials into the answer lines.

 AUTO-GENERATED SHARED SECRETS (Airflow FERNET_KEY, WEBSERVER_SECRET_KEY, admin pw)
   Declared under `secretGroups` in projectConfig(). Before any wave runs, the
   pipeline SSHes to the group's store host, generates each missing key ONCE
   (kept in a root-only file there, e.g. /etc/airflow-cluster/cluster.keys), reads
   all values back, and injects the SAME values into every task that lists them
   under `secrets:` (control node + every worker). Re-runs reuse the stored
   values - a key is never regenerated, so an existing cluster never breaks.
   BACK UP that file: losing it means losing the FERNET_KEY that encrypts the
   connections/variables in the Airflow DB.

 SECRETS
   Never put passwords in this file. Map ENV_NAME -> Jenkins "Secret text"
   credential ID under `creds:`. They are masked in the log, written to a
   chmod 600 run.sh on the target, and deleted right after the run.

 RUN-TIME PARAMETERS
   ONLY       comma list of task ids or tags to run  (e.g. "airflow" or "spark-master,pg")
              An id listed here runs even if the task has enabled:false.
   SKIP       comma list of task ids or tags to skip
   OVERRIDES  one per line:  KEY=VALUE  (applies to every task that defines KEY)
                             taskId.KEY=VALUE  (one task only). Not for secrets.
   DRY_RUN    validate + print the plan, touch no server
   PARALLEL_HOSTS  untick to run every host one at a time

 ASSUMPTIONS
   - Passwordless sudo for SSH_USER on every target.
   - Scripts live in ./scripts/ of the repo this job is configured for
     ("Pipeline script from SCM").
   - SSH private-key credential exists in Jenkins (SSH_CREDENTIALS_ID).
 =============================================================================
*/

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 6, unit: 'HOURS')
    }

    parameters {
        // ---------------- General ----------------
        string(name: 'SSH_USER', defaultValue: 'ubuntu', description: 'OS login user on all target servers')
        string(name: 'SSH_CREDENTIALS_ID', defaultValue: 'aws-ubuntu-ssh', description: 'Jenkins credential ID (SSH Username with private key)')
        text(name: 'SERVERS', defaultValue: '', description: 'Placement, one server per line:  host = service, service, ...   e.g.  10.0.1.23 = airflow-worker, spark-worker, chrome  (blank = use defaults / per-role params)')
        string(name: 'ONLY', defaultValue: '', description: 'Task ids / tags to run (blank = every enabled task)')
        string(name: 'SKIP', defaultValue: '', description: 'Task ids / tags to skip')
        text(name: 'OVERRIDES', defaultValue: '', description: 'KEY=VALUE or taskId.KEY=VALUE per line. Non-secret values only.')
        string(name: 'OPENSEARCH_HOSTS', defaultValue: '', description: 'OpenSearch IPv4 addresses, comma-separated. 1 = standalone, 2+ = cluster (first one generates the certificates). Blank = default in projectConfig()')
        string(name: 'AIRFLOW_WORKERS', defaultValue: '', description: 'Airflow worker IPs, comma-separated, any number (blank = list in projectConfig()). e.g. 10.0.1.21,10.0.1.22,10.0.1.23')
        string(name: 'SPARK_WORKERS', defaultValue: '', description: 'Spark worker IPs, comma-separated, any number (blank = list in projectConfig())')
        string(name: 'KAFKA_HOSTS', defaultValue: '', description: 'Kafka server IPs, comma-separated, any number (blank = list in projectConfig()). Each gets its OWN single-node KRaft broker.')
        string(name: 'CHROME_HOSTS', defaultValue: '', description: 'Servers that need Chrome + ChromeDriver, comma-separated, any number (blank = list in projectConfig())')
        booleanParam(name: 'PARALLEL_HOSTS', defaultValue: true, description: 'Run different hosts of the same wave in parallel')
        booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Validate and print plan only')

        // ---------------- PostgreSQL (pg_install_master.sh prompts) ----------------
        string(name: 'PG_VERSION', defaultValue: '17.6', description: '[pg] PostgreSQL version')
        string(name: 'PG_BASE_DIR', defaultValue: '/data', description: '[pg] Base volume / directory')
        string(name: 'PG_PORT', defaultValue: '5432', description: '[pg] Port')
        string(name: 'PG_SERVICE_USER', defaultValue: 'postgres', description: '[pg] OS service user')
        string(name: 'PG_REPLICA_IPS', defaultValue: '', description: '[pg] Replica IPs, comma-separated (blank = none)')
        choice(name: 'PG_OPEN_CLIENT_ACCESS', choices: ['N', 'Y'], description: '[pg] Open client access?')
        string(name: 'PG_APP_DB', defaultValue: 'appdb', description: '[pg] Application database name')

        // ---------------- Apache httpd (install_apache_httpd.sh prompts) ----------------
        string(name: 'HTTPD_BASE_DIR', defaultValue: '/opt/ausiytic', description: '[httpd] Base volume / directory')

        // ---------------- NiFi (install_nifi.sh prompts; password = Jenkins credential nifi-admin-password) ----------------
        string(name: 'NIFI_BASE_DIR', defaultValue: '/opt/ausiytic', description: '[nifi] Base volume / directory')
        string(name: 'NIFI_ADMIN_USER', defaultValue: 'admin', description: '[nifi] Admin user (password = Jenkins credential nifi-admin-password, min 12 chars)')
        choice(name: 'NIFI_PROXY_CHOICE', choices: ['2', '1', '3'], description: '[nifi] Proxy host choice: 1=public 2=private 3=both')

        // ---------------- Druid (druid_install.sh prompts) ----------------
        string(name: 'DRUID_VOLUME_NAME', defaultValue: 'ausiytic', description: "[druid] Volume: '/data' = absolute path, 'name' = under /opt, 'root' = /opt on root volume")

        // ---------------- OpenSearch Dashboards (opensearch_dashboards_install.sh) ----------------
        string(name: 'OSD_BASE_DIR', defaultValue: '/data/opensearch-dashboards', description: '[dashboards] Base directory (admin password = Jenkins credential opensearch-admin-password)')

        // ---------------- Kafka (install_kafka_kraft.sh prompts) ----------------
        string(name: 'KAFKA_BASE_DIR', defaultValue: '/opt/ausiytic', description: '[kafka] Base volume / directory')

        // ---------------- Polaris (polaris_install.sh prompts) ----------------
        string(name: 'POLARIS_BASE_DIR', defaultValue: '/opt/ausiytic', description: '[polaris] Base directory')
        string(name: 'S3_BUCKET', defaultValue: '', description: '[polaris] Existing S3 bucket (required for polaris)')
        string(name: 'S3_REGION', defaultValue: '', description: '[polaris] AWS region (blank = auto-detect)')
        string(name: 'S3_ROLE_ARN', defaultValue: '', description: '[polaris] IAM role ARN, e.g. arn:aws:iam::123456789012:role/name (required for polaris)')
        string(name: 'CATALOG_NAME', defaultValue: 'default', description: '[polaris] Catalog name')

        // ---------------- Chrome (chrome_install.sh prompt) ----------------
        string(name: 'CHROME_DOWNLOAD_DIR', defaultValue: '/opt/ausiytic/softwares', description: '[chrome] Download / scratch directory')
    }

    environment {
        SCRIPTS_DIR = 'scripts'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                sh "chmod +x ${SCRIPTS_DIR}/*.sh || true"
            }
        }

        stage('Plan & validate') {
            steps {
                script {
                    def plan = buildPlan()
                    if (plan.isEmpty()) {
                        error 'No tasks selected (check enabled flags / ONLY / SKIP).'
                    }
                    def errors = validatePlan(plan)
                    printPlan(plan)
                    if (!errors.isEmpty()) {
                        error "Plan validation failed:\n - " + errors.join("\n - ")
                    }
                }
            }
        }

        stage('Deploy') {
            steps {
                script {
                    executePlan(buildPlan(), params.DRY_RUN, params.PARALLEL_HOSTS)
                }
            }
        }
    }

    post {
        always {
            sh 'rm -rf .deploy || true'
            echo 'Deployment run finished - see per-task logs above.'
        }
    }
}

// =============================================================================
//  PROJECT CONFIG  -  the only part you edit per project
// =============================================================================
def projectConfig() {

    // ---- 1. Servers: logical name -> IP/hostname ---------------------------
    // Add / remove lines freely. Use CHANGE_ME for not-yet-known hosts.
    def P = parsePlacement(params.SERVERS)       // service -> [hosts], from the SERVERS parameter

    // OpenSearch nodes, in node order. 1 host = standalone, 2+ = cluster. Must be IPv4 addresses.
    def OS_HOSTS = P['opensearch'] ?: pickHosts(params.OPENSEARCH_HOSTS, ['172.31.6.212'])

    // Default host per service is used only when SERVERS does not place that service.
    def S = [
        PG           : hostOf(P, 'pg',               '172.31.6.212'),
        OPENSEARCH   : OS_HOSTS[0],                                  // first node: Dashboards connects here, CA is fetched from here
        DRUID        : hostOf(P, 'druid',            '172.31.11.87'),
        NIFI         : hostOf(P, 'nifi',             '172.31.10.254'),
        HTTPD        : hostOf(P, 'httpd',            '172.31.3.85'),
        DASHBOARDS   : hostOf(P, 'dashboards',       '172.31.3.85'),

        AIRFLOW_CTRL : hostOf(P, 'airflow-control',  'CHANGE_ME'),
        REDIS        : hostOf(P, 'redis',            'CHANGE_ME'),   // installed by the 'redis' task; or an existing Redis (see REDIS_MANAGED)
        SPARK_MASTER : hostOf(P, 'spark-master',     'CHANGE_ME'),
        SPARK_SINGLE : hostOf(P, 'spark-standalone', 'CHANGE_ME'),   // only for the single-node standalone option
        POLARIS      : hostOf(P, 'polaris',          'CHANGE_ME')
    ]

    // Worker fleets: one entry per node. Any number, any project.
    // The build parameters AIRFLOW_WORKERS / SPARK_WORKERS (comma-separated) win if filled in;
    // otherwise these defaults are used. Any count works: 1, 5, 7, 8, 20 ...
    def AIRFLOW_WORKER_HOSTS = P['airflow-worker'] ?: pickHosts(params.AIRFLOW_WORKERS, ['CHANGE_ME'])   // e.g. ['10.0.1.21', '10.0.1.22', ...]
    def SPARK_WORKER_HOSTS   = P['spark-worker'] ?: pickHosts(params.SPARK_WORKERS, ['CHANGE_ME'])   // e.g. ['10.0.2.31', '10.0.2.32', ...]
    def KAFKA_HOSTS          = P['kafka'] ?: pickHosts(params.KAFKA_HOSTS, ['CHANGE_ME'])   // one independent single-node broker per host
    def CHROME_HOSTS         = P['chrome'] ?: pickHosts(params.CHROME_HOSTS, ['CHANGE_ME'])   // any servers that run Selenium/headless browsers

    // ---- 2. Shared values (defined once, used by several tasks) -------------
    def OS_BASE  = '/data/opensearch'
    def OS_ROOT  = OS_BASE + '/search/opensearch'       // opensearch_install.sh default: <BASE_DIR>/search/opensearch
    def OS_CRED  = 'opensearch-admin-password'          // Jenkins Secret-text credential ID (admin password)

    // opensearch_install.sh inputs (same on every node)
    def OS = [
        OS_VERSION     : '3.3.2',
        BASE_DIR       : OS_BASE,
        OS_ROOT        : OS_ROOT,
        SERVICE_USER   : 'opensearch',
        HTTP_PORT      : '9200',
        TRANSPORT_PORT : '9300',
        CLUSTER_NAME   : 'dev-01',
        HEAP_SIZE      : ''                             // blank = 50% of RAM (max 31g); override per node, e.g. opensearch-2.HEAP_SIZE=1536m
    ]
    def OSD_VERSION = '3.3.0'                           // OpenSearch Dashboards version
    def OSD_BASE    = pv('OSD_BASE_DIR', '/data/opensearch-dashboards')

    def AIRFLOW = [
        BASE_DIR        : '/opt/ausiytic',
        SERVICE_USER    : 'airflow',
        PYTHON_VERSION  : '3.10.10',
        AIRFLOW_VERSION : '3.1.2',                      // MUST be the same on control + workers
        AIRFLOW_EXTRAS  : '',
        DB_HOST         : S.PG,                        // Postgres from the pg task below
        DB_PORT         : '5432',
        DB_NAME         : 'airflow',                    // database + user must already exist
        DB_USER         : 'airflow',
        REDIS_HOST      : S.REDIS,
        REDIS_PORT      : '6379',
        REDIS_DB        : '0',
        DAGS_FOLDER     : '/mnt/shared/airflow-dags'    // same shared mount on EVERY airflow node
    ]
    // Only EXTERNAL secrets stay as Jenkins credentials (the DB password must match
    // the Postgres user that already exists). Fernet/webserver/admin are auto-generated below.
    def AIRFLOW_CREDS = [
        DB_PASSWORD          : 'airflow-db-password'
        // REDIS_PASSWORD    : 'airflow-redis-password',   // uncomment if Redis needs auth
    ]
    def AIRFLOW_REQUIRED = ['DB_HOST', 'DB_PASSWORD', 'REDIS_HOST', 'FERNET_KEY', 'DAGS_FOLDER']

    // true  = Redis is installed by THIS pipeline ('redis' task): its password is auto-generated once,
    //         stored on the Redis server, and given to the redis task AND every Airflow node.
    // false = Redis already exists elsewhere: Airflow gets no generated Redis password
    //         (add REDIS_PASSWORD under AIRFLOW_CREDS above if that Redis requires auth).
    def REDIS_MANAGED = true
    def redisSecret = REDIS_MANAGED ? [[group: 'redis', keys: ['REDIS_PASSWORD']]] : []

    // Generated once, stored on the control node, shared with every airflow task.
    // generator types: fernet | hex32 | password
    def SECRET_GROUPS = [
        airflow: [
            host: S.AIRFLOW_CTRL,
            path: '/etc/airflow-cluster/cluster.keys',
            keys: [FERNET_KEY: 'fernet', WEBSERVER_SECRET_KEY: 'hex32', ADMIN_PASSWORD: 'password']
        ],
        redis: [
            host: S.REDIS,
            path: '/etc/redis-cluster/cluster.keys',
            keys: [REDIS_PASSWORD: 'password']
        ]
    ]

    def SPARK = [
        SPARK_VERSION  : '4.0.3',
        HADOOP_VARIANT : 'hadoop3',
        BASE_DIR       : '/opt/ausiytic',
        SERVICE_USER   : 'spark',
        MASTER_PORT    : '7077'
    ]

    def DRUID = [
        VOLUME_NAME : pv('DRUID_VOLUME_NAME', 'ausiytic'),   // '/data' = absolute; 'name' = under /opt; 'root' = /opt on root volume
        RECONFIGURE : false,            // true => --reconfigure (needed to change settings on an already-installed server)
        USE_PG      : false,
        PG_PORT     : '5432', PG_DBNAME: 'druid', PG_USER: 'druid',
        USE_AZURE   : false,
        AZ_ACCOUNT  : '', AZ_CONTAINER: 'druid'
    ]

    def tasks = []

    // =========================================================================
    //  EXISTING INSTALLS
    // =========================================================================

    // ---- DB1: PostgreSQL ----------------------------------------------------
    // stdin order: PG_VERSION, BASE_DIR, PG_PORT, SERVICE_USER, MASTER_IP,
    //              REPLICA_IPS, OPEN_CLIENT_ACCESS, APP_DB
    // Values come from the build parameters PG_* (see the parameters block).
    tasks << newTask(
        id: 'pg', service: 'pg', tags: ['db', 'postgres'], wave: 1, host: S.PG,
        script: 'pg_install_master.sh', mode: 'stdin',
        env: [PG_VERSION: pv('PG_VERSION', '17.6'), PG_BASE_DIR: pv('PG_BASE_DIR', '/data'),
              PG_PORT: pv('PG_PORT', '5432'), PG_SERVICE_USER: pv('PG_SERVICE_USER', 'postgres'),
              PG_MASTER_IP: S.PG, PG_REPLICA_IPS: pv('PG_REPLICA_IPS', ''),
              PG_OPEN_CLIENT_ACCESS: pv('PG_OPEN_CLIENT_ACCESS', 'N'), PG_APP_DB: pv('PG_APP_DB', 'appdb')],
        stdin: ['{{PG_VERSION}}', '{{PG_BASE_DIR}}', '{{PG_PORT}}', '{{PG_SERVICE_USER}}',
                '{{PG_MASTER_IP}}', '{{PG_REPLICA_IPS}}', '{{PG_OPEN_CLIENT_ACCESS}}', '{{PG_APP_DB}}']
    )

    // ---- DB1: OpenSearch (standalone OR cluster) -----------------------------
    // opensearch_install.sh in AUTOMATED mode (env vars, no stdin).
    //   1 host  -> MODE=standalone, task id 'opensearch'
    //   N hosts -> MODE=cluster,    task ids 'opensearch-1' .. 'opensearch-N'
    //              node 1 = wave 1 (generates CA + passwords + bundles; Jenkins relays each
    //              peer's bundle to the peer's /tmp), nodes 2..N = wave 2 (in parallel).
    //              The last node waits until every node has joined the cluster.
    //   Cluster-manager-eligible nodes = the first 3 hosts (first 1 if there are only 2 hosts);
    //   override with CLUSTER_MANAGER_IPS=ip1,ip2,... ; roles per node with taskId.NODE_ROLES=...
    //   The admin password comes from the OS_CRED credential (first node only; the peers
    //   receive it inside their bundle). The other passwords are generated by the script.
    def osCount = OS_HOSTS.size()
    def osCluster = osCount > 1
    def osNames = []
    for (int i = 0; i < osCount; i++) { osNames << ('os-node-' + (i + 1)) }
    def osMgrIps = OS_HOSTS.take(osCount >= 3 ? 3 : 1)
    def ipv4Re = '^([0-9]{1,3}[.]){3}[0-9]{1,3}$'
    def ipv4ListRe = '^([0-9]{1,3}[.]){3}[0-9]{1,3}(,([0-9]{1,3}[.]){3}[0-9]{1,3})*$'

    for (int i = 0; i < osCount; i++) {
        def oEnv = [:]
        oEnv.putAll(OS)
        oEnv.putAll([MODE: osCluster ? 'cluster' : 'standalone', THIS_NODE_IP: OS_HOSTS[i], NODE_ROLES: ''])
        def oPatterns = [THIS_NODE_IP: ipv4Re]
        def oFetch = []
        if (osCluster) {
            oEnv.putAll([NODE_IPS: OS_HOSTS.join(','), NODE_NAMES: osNames.join(','),
                         CLUSTER_MANAGER_IPS: osMgrIps.join(','), TRANSFER_TO_PEERS: 'N',
                         HEALTH_WAIT_SECS: (i == osCount - 1) ? '300' : '0'])    // only the last node waits for the full cluster
            oPatterns['NODE_IPS'] = ipv4ListRe
            oPatterns['CLUSTER_MANAGER_IPS'] = ipv4ListRe
            if (i > 0) {
                // Peers cannot create certificates: copy this node's bundle from the first node
                // (root-only dir there, so read it with sudo) into /tmp here, delete it after the run.
                oFetch << [fromHost: OS_HOSTS[0],
                           fromPath: OS_ROOT + '/bundles/opensearch_bundle_' + OS_HOSTS[i] + '.tar.gz',
                           toPath: '/tmp/opensearch_bundle_' + OS_HOSTS[i] + '.tar.gz',
                           sudo: true, cleanup: true, required: true]
            }
        } else {
            oEnv.put('NODE_NAME', 'os-node-1')
        }
        tasks << newTask(
            id: osCluster ? ('opensearch-' + (i + 1)) : 'opensearch', service: 'opensearch', tags: ['db', 'opensearch'],
            wave: (i == 0) ? 1 : 2, host: OS_HOSTS[i],
            script: 'opensearch_install.sh', mode: 'env', timeoutMin: 60,
            maskLogs: true,                                  // the script prints its credentials file at the end
            env: oEnv,
            creds: (i == 0) ? [ADMIN_PASSWORD: OS_CRED] : [:],
            required: (i == 0) ? ['ADMIN_PASSWORD'] : [],
            patterns: oPatterns,
            fetch: oFetch
        )
    }

    // ---- DB2: Druid -----------------------------------------------------------
    // stdin order (only read on first run / --reconfigure):
    //   VOLUME_NAME, PG host(+port,db,user,pw if set), Azure acct(+container,key if set),
    //   admin password, internal password
    def druidLines = ['{{DRUID_VOLUME_NAME}}']
    def druidCreds = [:]
    if (DRUID.USE_PG) {
        druidLines += [S.PG, DRUID.PG_PORT, DRUID.PG_DBNAME, DRUID.PG_USER, '{{DRUID_PG_PASSWORD}}']
        druidCreds['DRUID_PG_PASSWORD'] = 'druid-pg-password'
    } else {
        druidLines += ['']
    }
    if (DRUID.USE_AZURE) {
        druidLines += [DRUID.AZ_ACCOUNT, DRUID.AZ_CONTAINER, '{{DRUID_AZURE_KEY}}']
        druidCreds['DRUID_AZURE_KEY'] = 'druid-azure-key'
    } else {
        druidLines += ['']
    }
    druidLines += ['', '']                                   // blank = script auto-generates both passwords
    tasks << newTask(
        id: 'druid', service: 'druid', tags: ['db', 'druid'], wave: 2, host: S.DRUID,
        script: 'druid_install.sh', mode: 'stdin',
        env: [DRUID_VOLUME_NAME: DRUID.VOLUME_NAME],
        creds: druidCreds,
        flags: DRUID.RECONFIGURE ? '--reconfigure' : '',
        stdin: druidLines,
        preDirs: druidPreDirs(DRUID.VOLUME_NAME)             // prompt_volume() loops forever if dir is missing
    )

    // ---- DI: NiFi ---------------------------------------------------------------
    // stdin order: DISK_MOUNT, ADMIN_USER, ADMIN_PASS, ADMIN_PASS(confirm), PROXY_CHOICE[, CUSTOM_HOST]
    def nifiBase = pv('NIFI_BASE_DIR', '/opt/ausiytic')
    tasks << newTask(
        id: 'nifi', service: 'nifi', tags: ['di', 'nifi'], wave: 1, host: S.NIFI,
        script: 'install_nifi.sh', mode: 'stdin',
        env: [NIFI_BASE_DIR: nifiBase, NIFI_ADMIN_USER: pv('NIFI_ADMIN_USER', 'admin'),
              NIFI_PROXY_CHOICE: pv('NIFI_PROXY_CHOICE', '2')],   // 1=public 2=private 3=both 4=custom
        creds: [NIFI_ADMIN_PASSWORD: 'nifi-admin-password'],
        minLen: [NIFI_ADMIN_PASSWORD: 12],
        stdin: ['{{NIFI_BASE_DIR}}', '{{NIFI_ADMIN_USER}}', '{{NIFI_ADMIN_PASSWORD}}',
                '{{NIFI_ADMIN_PASSWORD}}', '{{NIFI_PROXY_CHOICE}}'],   // append '{{NIFI_CUSTOM_HOST}}' if choice 4
        preDirs: [nifiBase]                                  // prompt_disk() dies if the path is missing
    )

    // ---- APP: Apache httpd ---------------------------------------------------------
    def httpdBase = pv('HTTPD_BASE_DIR', '/opt/ausiytic')
    tasks << newTask(
        id: 'httpd', service: 'httpd', tags: ['app', 'httpd'], wave: 1, host: S.HTTPD,
        script: 'install_apache_httpd.sh', mode: 'stdin',
        env: [HTTPD_BASE_DIR: httpdBase],
        stdin: ['{{HTTPD_BASE_DIR}}', 'y'],
        preDirs: [httpdBase]                                 // create the base dir first, as the script expects it to exist
    )

    // ---- APP: OpenSearch Dashboards 3.3.0 (needs the OpenSearch cluster complete) ------
    // Wave 3 for a cluster (nodes 2..N are wave 2), wave 2 for a standalone node.
    // OS_ADMIN_PASSWORD is the same OS_CRED credential that set OpenSearch's admin password.
    tasks << newTask(
        id: 'dashboards', service: 'dashboards', tags: ['app', 'opensearch'], wave: osCluster ? 3 : 2, host: S.DASHBOARDS,
        script: 'opensearch_dashboards_install.sh', mode: 'stdin',
        env: [OSD_VERSION: OSD_VERSION],
        creds: [OS_ADMIN_PASSWORD: OS_CRED],
        exportEnv: ['OS_ADMIN_PASSWORD', 'OSD_VERSION'],
        // The password flag references the exported env var (resolved by the remote shell).
        flags: "--base-dir '${OSD_BASE}' --opensearch-host '${S.OPENSEARCH}' --opensearch-port '${OS.HTTP_PORT}' " +
               "--opensearch-user 'admin' --opensearch-password \"\$OS_ADMIN_PASSWORD\" --bind-host '0.0.0.0'",
        // Dashboards runs here but OpenSearch's CA lives on the first OpenSearch node -> copy it across
        // (the certs dir there is private to the service user, so it is read with sudo; non-fatal if missing)
        fetch: [[fromHost: S.OPENSEARCH, fromPath: OS_ROOT + '/binaries/config/certs/root-ca.pem',
                 toPath: '/tmp/opensearch-root-ca.pem', sudo: true,
                 flag: "--opensearch-root-ca '/tmp/opensearch-root-ca.pem'"]],
        stdin: ['Y']
    )

    // =========================================================================
    //  NEW: APACHE AIRFLOW (CeleryExecutor cluster)
    //  Prereqs (not installed by these scripts): Postgres DB+user for airflow,
    //  a reachable Redis, and the shared DAGs mount on every airflow node.
    //  Flip enabled:true after replacing the CHANGE_ME hosts above.
    // =========================================================================
    def airflowSupport = ['airflow_cluster_common.sh']       // sourced by control + worker scripts

    def ctrlEnv = [:]
    ctrlEnv.putAll(AIRFLOW)
    ctrlEnv.putAll([API_PORT: '8080', JWT_ISSUER: 'airflow-api', ADMIN_USERNAME: 'admin',
                    INSTALL_FLOWER: '0', FLOWER_PORT: '5555'])

    tasks << newTask(
        id: 'airflow-control', service: 'airflow-control', tags: ['airflow'], wave: 3, host: S.AIRFLOW_CTRL, enabled: false,
        script: 'airflow_cluster_scheduler.sh', files: airflowSupport, timeoutMin: 90,
        env: ctrlEnv, creds: AIRFLOW_CREDS,
        secrets: [[group: 'airflow', keys: ['FERNET_KEY', 'WEBSERVER_SECRET_KEY', 'ADMIN_PASSWORD']]] + redisSecret,
        required: AIRFLOW_REQUIRED + ['WEBSERVER_SECRET_KEY', 'ADMIN_PASSWORD']
    )

    for (int i = 0; i < AIRFLOW_WORKER_HOSTS.size(); i++) {
        def wEnv = [:]
        wEnv.putAll(AIRFLOW)
        wEnv.putAll([WORKER_QUEUES: 'default', WORKER_CONCURRENCY: '16'])
        tasks << newTask(
            id: "airflow-worker-${i + 1}", service: 'airflow-worker', tags: ['airflow', 'airflow-worker'], wave: 4,
            host: AIRFLOW_WORKER_HOSTS[i], enabled: false,
            script: 'airflow_cluster_worker.sh', files: airflowSupport, timeoutMin: 90,
            env: wEnv, creds: AIRFLOW_CREDS, required: AIRFLOW_REQUIRED,
            secrets: [[group: 'airflow', keys: ['FERNET_KEY', 'WEBSERVER_SECRET_KEY']]] + redisSecret   // same values as control
        )
    }

    // =========================================================================
    //  NEW: APACHE SPARK   -  choose ONE style per project
    // =========================================================================

    // ---- Option A: multi-node standalone cluster (master + N workers) -----------
    // NOTE: rename spark_install__5_.sh to spark_install.sh in ./scripts/
    tasks << newTask(
        id: 'spark-master', service: 'spark-master', tags: ['spark', 'spark-cluster'], wave: 1, host: S.SPARK_MASTER, enabled: false,
        script: 'spark_install.sh',
        env: sparkEnv(SPARK, [SPARK_ROLE: 'master', MASTER_IP: S.SPARK_MASTER,
                              MASTER_UI_PORT: '8080']),
        required: ['MASTER_IP']
    )
    for (int i = 0; i < SPARK_WORKER_HOSTS.size(); i++) {
        tasks << newTask(
            id: "spark-worker-${i + 1}", service: 'spark-worker', tags: ['spark', 'spark-cluster'], wave: 2,
            host: SPARK_WORKER_HOSTS[i], enabled: false,
            script: 'spark_install.sh',
            env: sparkEnv(SPARK, [SPARK_ROLE: 'worker', MASTER_IP: S.SPARK_MASTER,
                                  WORKER_UI_PORT: '8081']),
            required: ['MASTER_IP']
        )
    }

    // ---- Option B: single-node standalone (master + worker on one box) ----------
    tasks << newTask(
        id: 'spark-standalone', service: 'spark-standalone', tags: ['spark', 'spark-single'], wave: 1, host: S.SPARK_SINGLE, enabled: false,
        script: 'spark_standalone_install.sh',
        env: sparkEnv(SPARK, [MASTER_IP: S.SPARK_SINGLE, MASTER_UI_PORT: '8080',
                              WORKER_UI_PORT: '8081', WORKER_CORES: '0', WORKER_MEMORY: '0'])
    )

    // =========================================================================
    //  NEW: REDIS  -  redis_install.sh  (builds from source, systemd, ACL password)
    //  Takes the base disk path as its only argument. The path must already exist
    //  (preDirs creates it). The password is auto-generated and shared with Airflow
    //  (see REDIS_MANAGED). Wave 1 so it is up before the Airflow nodes (waves 3/4).
    //  REQUIRES the small patched redis_install.sh (reads REDIS_PASSWORD from the env).
    // =========================================================================
    tasks << newTask(
        id: 'redis', service: 'redis', tags: ['redis'], wave: 1, host: S.REDIS, enabled: false,
        script: 'redis_install.sh', mode: 'env', timeoutMin: 45,
        env: [REDIS_BASE_DIR: '/opt/ausiytic'],
        secrets: [[group: 'redis', keys: ['REDIS_PASSWORD']]],
        required: ['REDIS_BASE_DIR', 'REDIS_PASSWORD'],
        flags: '"$REDIS_BASE_DIR"',                      // positional arg <disk-name>
        preDirs: ['{{REDIS_BASE_DIR}}']
    )

    // =========================================================================
    //  NEW: APACHE KAFKA (KRaft, no ZooKeeper)  -  install_kafka_kraft.sh
    //  The script builds a SINGLE-NODE combined broker+controller. Listing N hosts
    //  gives you N independent single-node brokers (NOT one N-node cluster).
    //  stdin order: BASE_DIR, NODE_ID, ADVERTISED_HOST, confirm
    // =========================================================================
    for (int i = 0; i < KAFKA_HOSTS.size(); i++) {
        tasks << newTask(
            id: "kafka-${i + 1}", service: 'kafka', tags: ['kafka'], wave: 1, host: KAFKA_HOSTS[i], enabled: false,
            script: 'install_kafka_kraft.sh', mode: 'stdin',
            env: [KAFKA_BASE_DIR: pv('KAFKA_BASE_DIR', '/opt/ausiytic'), KAFKA_NODE_ID: "${i + 1}",
                  KAFKA_ADVERTISED_HOST: KAFKA_HOSTS[i]],        // address clients use to reach this broker
            required: ['KAFKA_BASE_DIR', 'KAFKA_ADVERTISED_HOST'],
            stdin: ['{{KAFKA_BASE_DIR}}', '{{KAFKA_NODE_ID}}', '{{KAFKA_ADVERTISED_HOST}}', 'y']
        )
    }

    // =========================================================================
    //  NEW: APACHE POLARIS (S3-backed Iceberg REST catalog)  -  polaris_install.sh
    //  Needs: an existing S3 bucket + an IAM role ARN (EC2 instance role recommended).
    //  NOTE: the script uses in-memory persistence - a restart of polaris.service wipes
    //  catalogs and root credentials. Root creds are saved on the server by the script.
    //  stdin order: BASE_DIR, S3_BUCKET, REGION (blank = auto-detect), ROLE_ARN,
    //               CATALOG_NAME, confirm
    // =========================================================================
    tasks << newTask(
        id: 'polaris', service: 'polaris', tags: ['polaris', 'iceberg'], wave: 1, host: S.POLARIS, enabled: false,
        script: 'polaris_install.sh', mode: 'stdin',
        env: [POLARIS_BASE_DIR: pv('POLARIS_BASE_DIR', '/opt/ausiytic'), S3_BUCKET: pv('S3_BUCKET', ''),
              S3_REGION: pv('S3_REGION', ''), S3_ROLE_ARN: pv('S3_ROLE_ARN', ''),
              CATALOG_NAME: pv('CATALOG_NAME', 'default')],
        required: ['POLARIS_BASE_DIR', 'S3_BUCKET', 'S3_ROLE_ARN'],
        // the script re-prompts (and would swallow the next answers) on a malformed ARN - catch it up front
        patterns: [S3_ROLE_ARN: '^arn:aws:iam::[0-9]{12}:role/.+'],
        stdin: ['{{POLARIS_BASE_DIR}}', '{{S3_BUCKET}}', '{{S3_REGION}}', '{{S3_ROLE_ARN}}',
                '{{CATALOG_NAME}}', 'y']
    )

    // =========================================================================
    //  NEW: GOOGLE CHROME + CHROMEDRIVER  -  chrome_install.sh
    //  The Chrome build (CHROME_BUILD="151.0.7922") is hard-coded INSIDE the script, so
    //  to change the version edit the script in the repo. The script resolves the
    //  newest published patch of that build and verifies Chrome == ChromeDriver.
    //  stdin order: scratch/download directory
    //  NOTE: rename chrome_install (4).sh -> chrome_install.sh in ./scripts/
    // =========================================================================
    for (int i = 0; i < CHROME_HOSTS.size(); i++) {
        tasks << newTask(
            id: "chrome-${i + 1}", service: 'chrome', tags: ['chrome'], wave: 1, host: CHROME_HOSTS[i], enabled: false,
            script: 'chrome_install.sh', mode: 'stdin',
            env: [CHROME_DOWNLOAD_DIR: pv('CHROME_DOWNLOAD_DIR', '/opt/ausiytic/softwares')],
            required: ['CHROME_DOWNLOAD_DIR'],
            stdin: ['{{CHROME_DOWNLOAD_DIR}}']
        )
    }

    // =========================================================================
    //  COPY-PASTE TEMPLATE for any new script / server:
    //
    //  tasks << newTask(
    //      id: 'my-task', tags: ['mygroup'], wave: 2, host: S.SOME_SERVER,
    //      script: 'my_install.sh',                  // file in ./scripts/
    //      files: ['helper_lib.sh'],                 // optional: sourced/support files
    //      mode: 'env',                              // or 'stdin' (+ stdin: [...])
    //      env:   [FOO: pv('FOO', 'bar')],           // pv() reads a build parameter, with a default
    //      creds: [DB_PASSWORD: 'jenkins-credential-id'],
    //      required: ['FOO', 'DB_PASSWORD'],
    //      flags: '--some-flag value',               // CLI args for the script
    //      preDirs: ['/data'],                       // mkdir -p before running
    //      maskLogs: true,                           // mask "...PASSWORD=value" lines in the build log
    //      fetch: [[fromHost: 'x', fromPath: '/p', toPath: '/tmp/p', sudo: true]],  // copy a file host->host via Jenkins
    //      timeoutMin: 60
    //  )
    //  Then add  string(name: 'FOO', defaultValue: 'bar', description: '...')  to the parameters block.
    // =========================================================================

    return [servers: S, tasks: tasks, secretGroups: SECRET_GROUPS]
}

// Helpers used by the config above --------------------------------------------
def newTask(Map m) {
    def d = [service: '', enabled: true, wave: 1, tags: [], files: [], mode: 'env', env: [:], creds: [:],
             required: [], minLen: [:], patterns: [:], exportEnv: [], secrets: [], flags: '', stdin: [], preDirs: [],
             fetch: [], maskLogs: false, timeoutMin: 60]
    d.putAll(m)
    // secrets: a single [group:, keys:] map or a list of them -> always a list
    if (d.secrets instanceof Map) { d.secrets = d.secrets.isEmpty() ? [] : [d.secrets] }
    d.id = d.id.toString()
    d.host = d.host.toString()
    d.wave = d.wave as int
    return d
}

// Value of a build parameter. Falls back to the default when the parameter is missing
// (e.g. the form has not been reloaded yet after the Jenkinsfile changed) or blank.
// Pass '' as the default for values that are allowed to stay blank.
def pv(String name, String dflt) {
    def v = params[name]
    if (v == null) { return dflt }
    def s = v.toString().trim()
    return s ? s : dflt
}

def sparkEnv(Map base, Map extra) {
    def e = [:]
    e.putAll(base)
    e.putAll(extra)
    return e
}

// Same path resolution as druid_install.sh v6: '/x' absolute, 'name' -> /opt/name, 'root' -> nothing to create
def druidPreDirs(String raw) {
    def v = raw.trim().replaceAll('/+$', '')
    if (v == 'root' || v == '') { return [] }
    return [v.startsWith('/') ? v : "/opt/${v}"]
}

// =============================================================================
//  ENGINE  -  generic, no project-specific content below this line
// =============================================================================

// Every service name the SERVERS parameter accepts.
def knownServices() {
    return ['pg', 'opensearch', 'dashboards', 'druid', 'nifi', 'httpd', 'redis',
            'airflow-control', 'airflow-worker', 'spark-master', 'spark-worker', 'spark-standalone',
            'kafka', 'chrome', 'polaris']
}

// Services that may be placed on MANY servers; everything else is one-per-project.
def multiServices() {
    return ['opensearch', 'airflow-worker', 'spark-worker', 'kafka', 'chrome']
}

// "host = svc, svc" lines  ->  [service: [hosts]]
def parsePlacement(String raw) {
    def res = [:]
    def known = knownServices()
    for (rawLine in (raw ?: '').split('\n')) {
        def line = rawLine.replaceAll('#.*$', '').trim()
        if (!line) { continue }
        int sep = line.indexOf('=')
        if (sep < 0) { sep = line.indexOf(':') }
        if (sep < 1) { error "Bad SERVERS line (expected 'host = service, service'): ${line}" }
        def host = line.substring(0, sep).trim()
        for (svc in csv(line.substring(sep + 1))) {
            if (!known.contains(svc)) { error "Unknown service '${svc}' in SERVERS. Valid: ${known.join(', ')}" }
            if (!res.containsKey(svc)) { res[svc] = [] }
            if (!res[svc].contains(host)) { res[svc] << host }
        }
    }
    def multi = multiServices()
    for (svc in res.keySet()) {
        if (!multi.contains(svc) && res[svc].size() > 1) {
            error "Service '${svc}' can only be placed on ONE server, but SERVERS lists: ${res[svc].join(', ')}"
        }
    }
    return res
}

// Host for a single-instance service: from SERVERS if placed, else the default.
def hostOf(Map placement, String service, String dflt) {
    def hosts = placement[service]
    return (hosts && !hosts.isEmpty()) ? hosts[0] : dflt
}

// Hosts from a comma-separated build parameter (de-duplicated, order kept), else the config default.
def pickHosts(String paramValue, List defaults) {
    def fromParam = []
    for (h in csv(paramValue)) {
        if (!fromParam.contains(h)) { fromParam << h }
    }
    return fromParam.isEmpty() ? defaults : fromParam
}

def csv(String s) {
    def out = []
    for (p in (s ?: '').split(',')) {
        if (p.trim()) { out << p.trim() }
    }
    return out
}

def matchesAny(Map t, List keys) {
    if (keys.contains(t.id)) { return true }
    for (tag in t.tags) {
        if (keys.contains(tag)) { return true }
    }
    return false
}

def parseOverrides(String raw) {
    def res = [global: [:], perTask: [:]]
    for (rawLine in (raw ?: '').split('\n')) {
        def line = rawLine.trim()
        if (!line || line.startsWith('#')) { continue }
        int eq = line.indexOf('=')
        if (eq < 1) { error "Bad OVERRIDES line (need KEY=VALUE): ${line}" }
        def k = line.substring(0, eq).trim()
        def v = line.substring(eq + 1)
        int dot = k.indexOf('.')
        if (dot > 0) {
            def tid = k.substring(0, dot)
            if (!res.perTask.containsKey(tid)) { res.perTask[tid] = [:] }
            res.perTask[tid][k.substring(dot + 1)] = v
        } else {
            res.global[k] = v
        }
    }
    return res
}

// Selected tasks, with OVERRIDES applied.
def buildPlan() {
    def cfg = projectConfig()
    def only = csv(params.ONLY)
    def skip = csv(params.SKIP)
    def ov = parseOverrides(params.OVERRIDES)
    def placement = parsePlacement(params.SERVERS)
    def plan = []

    for (t in cfg.tasks) {
        if (!placement.isEmpty()) {
            // SERVERS given: run exactly the placed services (enabled flags ignored);
            // ONLY/SKIP can still narrow it further.
            if (!t.service || !placement.containsKey(t.service)) { continue }
            if (!only.isEmpty() && !matchesAny(t, only)) { continue }
        } else if (!only.isEmpty()) {
            if (!matchesAny(t, only)) { continue }
        } else if (!t.enabled) {
            continue
        }
        if (!skip.isEmpty() && matchesAny(t, skip)) { continue }

        for (k in ov.global.keySet()) {
            if (t.env.containsKey(k)) { t.env[k] = ov.global[k] }
        }
        if (ov.perTask.containsKey(t.id)) {
            for (k in ov.perTask[t.id].keySet()) { t.env[k] = ov.perTask[t.id][k] }
        }
        plan << t
    }
    return plan
}

def validatePlan(List plan) {
    def errors = []
    def seen = [:]
    for (t in plan) {
        def p = "[${t.id}]"
        if (seen.containsKey(t.id)) { errors << "${p} duplicate task id" }
        seen[t.id] = true

        if (!(t.host ==~ /^[A-Za-z0-9.\-]+$/) || t.host.contains('CHANGE_ME')) {
            errors << "${p} host '${t.host}' is not set - fix the servers / worker host list in projectConfig()"
        }
        if (!(t.mode in ['env', 'stdin'])) { errors << "${p} mode must be 'env' or 'stdin'" }
        if (!fileExists("${env.SCRIPTS_DIR}/${t.script}")) { errors << "${p} missing ${env.SCRIPTS_DIR}/${t.script}" }
        for (f in t.files) {
            if (!fileExists("${env.SCRIPTS_DIR}/${f}")) { errors << "${p} missing support file ${env.SCRIPTS_DIR}/${f}" }
        }
        for (k in t.required) {
            def v = t.env[k]?.toString()?.trim()
            def fromSecrets = false
            for (sc in t.secrets) { if (sc.keys.contains(k)) { fromSecrets = true } }
            if (!v && !t.creds.containsKey(k) && !fromSecrets) { errors << "${p} required value ${k} is empty (set it in env or creds)" }
            if (v && v.contains('CHANGE_ME')) { errors << "${p} ${k} is still CHANGE_ME" }
        }
        for (sc in t.secrets) {
            def grp = projectConfig().secretGroups[sc.group]
            if (!grp) {
                errors << "${p} unknown secret group '${sc.group}'"
            } else {
                for (k in sc.keys) {
                    if (!grp.keys.containsKey(k)) { errors << "${p} secret ${k} is not defined in group '${sc.group}'" }
                }
            }
        }
        for (k in t.patterns.keySet()) {
            def pv = t.env[k]?.toString()?.trim()
            if (pv && !pv.contains('CHANGE_ME') && !(pv ==~ t.patterns[k])) {
                errors << "${p} ${k}='${pv}' does not match the expected format ${t.patterns[k]}"
            }
        }
        for (d in t.preDirs) {
            if (!d.contains('{{') && !(d ==~ /^\/[A-Za-z0-9_.\/\-]+$/)) { errors << "${p} unsafe preDir '${d}'" }
        }
        for (k in t.creds.keySet()) {
            if (!t.creds[k]?.toString()?.trim()) { errors << "${p} credential id for ${k} is blank" }
        }
    }
    return errors
}

def printPlan(List plan) {
    def lines = ['', "Deployment plan (${plan.size()} task(s)):"]
    def waves = []
    for (t in plan) { if (!waves.contains(t.wave)) { waves << t.wave } }
    waves.sort()
    for (w in waves) {
        lines << "  Wave ${w}:"
        for (t in plan) {
            if (t.wave == w) {
                lines << "    - ${t.id.padRight(20)} ${t.host.padRight(16)} ${t.script}  [${t.mode}]" +
                         (t.creds.isEmpty() ? '' : "  creds: ${t.creds.keySet().join(',')}")
                // show the non-secret inputs that came from the build parameters
                if (t.mode == 'stdin') {
                    def shown = []
                    for (k in t.env.keySet()) { shown << "${k}=${t.env[k]}" }
                    if (!shown.isEmpty()) { lines << "        inputs: " + shown.join(', ') }
                }
            }
        }
    }
    echo lines.join('\n')
}

def executePlan(List plan, boolean dryRun, boolean parallelHosts) {
    if (dryRun) {
        echo 'DRY_RUN=true - nothing executed.'
        return
    }
    def waves = []
    for (t in plan) { if (!waves.contains(t.wave)) { waves << t.wave } }
    waves.sort()

    // Generate-once / read-back of shared secrets, BEFORE any install starts.
    def sharedSecrets = resolveSharedSecrets(plan)

    for (w in waves) {
        def wave = w
        stage("Wave ${wave}") {
            // group this wave's tasks by host (same host => sequential)
            def byHost = [:]
            for (t in plan) {
                if (t.wave == wave) {
                    if (!byHost.containsKey(t.host)) { byHost[t.host] = [] }
                    byHost[t.host] << t
                }
            }
            def branches = [:]
            for (h in byHost.keySet()) {
                def hostTasks = byHost[h]
                branches["${h}"] = {
                    for (ht in hostTasks) {
                        def task = ht
                        stage("${task.id} @ ${task.host}") {
                            timeout(time: task.timeoutMin as int, unit: 'MINUTES') {
                                runTask(task, sharedSecrets)
                            }
                        }
                    }
                }
            }
            if (parallelHosts && branches.size() > 1) {
                branches.failFast = false      // let running installs finish instead of killing them mid-apt
                parallel branches
            } else {
                branches.remove('failFast')
                for (k in branches.keySet()) { branches[k]() }
            }
        }
    }
}

// For every secret group used by the plan: make sure each key exists on the store host
// (generate if missing, never overwrite), then read them all back. Returns [group: [KEY: value]].
def resolveSharedSecrets(List plan) {
    def cfg = projectConfig()
    def groups = []
    for (t in plan) {
        for (sc in t.secrets) {
            if (!groups.contains(sc.group)) { groups << sc.group }
        }
    }
    def out = [:]
    for (g in groups) {
        out[g] = ensureSharedSecrets(g, cfg.secretGroups[g])
    }
    return out
}

def ensureSharedSecrets(String name, Map grp) {
    def gens = [
        fernet  : 'head -c32 /dev/urandom | base64 | tr "+/" "-_" | tr -d "\\n"',   // valid Fernet key (urlsafe b64 of 32 bytes)
        hex32   : 'od -An -tx1 -N16 /dev/urandom | tr -d " \\n"',                   // 32 hex chars
        password: 'head -c48 /dev/urandom | base64 | tr -dc "A-Za-z0-9" | head -c24'
    ]
    if (!(grp.host ==~ /^[A-Za-z0-9.\-]+$/) || grp.host.contains('CHANGE_ME')) {
        error "Secret group '${name}': store host '${grp.host}' is not set."
    }
    if (!(grp.path ==~ /^\/[A-Za-z0-9_.\/\-]+$/)) { error "Secret group '${name}': unsafe path '${grp.path}'" }

    def sb = new StringBuilder()
    sb << '#!/bin/bash\nset -e\numask 077\n'
    sb << 'F=' + shq(grp.path) + '\n'
    sb << 'mkdir -p "$(dirname "$F")"\ntouch "$F"\nchmod 600 "$F"\n'
    for (k in grp.keys.keySet()) {
        if (!(k ==~ /^[A-Z_][A-Z0-9_]*$/)) { error "Secret group '${name}': bad key name '${k}'" }
        def gen = gens[grp.keys[k]]
        if (!gen) { error "Secret group '${name}': unknown generator '${grp.keys[k]}' for ${k}" }
        sb << 'grep -q "^' + k + '=" "$F" || echo "' + k + '=$(' + gen + ')" >> "$F"\n'
    }
    sb << 'cat "$F"\n'

    def sshOpts = '-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15'
    def SSH = 'ssh -i "$SSH_KEY" ' + sshOpts
    def SCP = 'scp -i "$SSH_KEY" ' + sshOpts
    def target = "${params.SSH_USER}@${grp.host}"
    def jobSafe = env.JOB_BASE_NAME.replaceAll('[^A-Za-z0-9_.-]', '_')
    def rdir = "/tmp/jenkins-deploy-${jobSafe}/secrets-${name}"
    def ldir = ".deploy/secrets-${name}"
    def result = [:]

    withCredentials([sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID,
                                       keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER_CRED')]) {
        try {
            sh "mkdir -p ${ldir}"
            writeFile(file: "${ldir}/gen.sh", text: sb.toString())
            sh "${SSH} ${target} 'mkdir -p ${rdir} && chmod 700 ${rdir}'"
            sh "${SCP} ${ldir}/gen.sh ${target}:${rdir}/gen.sh"
            // returnStdout: values are never echoed to the build log
            def raw = sh(script: "${SSH} ${target} 'sudo -n bash ${rdir}/gen.sh'", returnStdout: true)
            for (line in raw.split('\n')) {
                if (line ==~ /^[A-Z_][A-Z0-9_]*=.+$/) {
                    int eq = line.indexOf('=')
                    result[line.substring(0, eq)] = line.substring(eq + 1).trim()
                }
            }
            for (k in grp.keys.keySet()) {
                if (!result.containsKey(k)) { error "Secret group '${name}': ${k} missing on ${grp.host}:${grp.path} after generation." }
            }
            echo "Shared secret group '${name}' ready (${grp.keys.keySet().join(', ')}) - stored at ${grp.host}:${grp.path}, values not logged."
        } finally {
            sh(script: "${SSH} ${target} 'rm -f ${rdir}/gen.sh'", returnStatus: true)
            sh "rm -rf ${ldir} || true"
        }
    }
    return result
}

@NonCPS
def shq(String v) {
    return "'" + v.replace("'", "'\\''") + "'"
}

def renderTokens(String s, Map vals) {
    def out = s
    for (k in vals.keySet()) {
        out = out.replace('{{' + k + '}}', vals[k])
    }
    if (out.contains('{{')) { error "Unresolved {{token}} in: ${s}" }
    return out
}

// Upload script(+support files) and a generated run.sh, execute as root, clean up.
def runTask(Map t, Map sharedSecrets) {
    def sshOpts = '-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 ' +
                  '-o ServerAliveInterval=30 -o ServerAliveCountMax=40'
    def SSH = 'ssh -i "$SSH_KEY" ' + sshOpts      // single quotes: $SSH_KEY is expanded by the shell, not Groovy
    def SCP = 'scp -i "$SSH_KEY" ' + sshOpts
    def target = "${params.SSH_USER}@${t.host}"
    def jobSafe = env.JOB_BASE_NAME.replaceAll('[^A-Za-z0-9_.-]', '_')
    def rdir = "/tmp/jenkins-deploy-${jobSafe}/${t.id}"
    def ldir = ".deploy/${t.id}"

    def bindings = [sshUserPrivateKey(credentialsId: params.SSH_CREDENTIALS_ID,
                                      keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER_CRED')]
    def credKeys = t.creds.keySet() as List
    for (k in credKeys) {
        bindings << string(credentialsId: t.creds[k].toString(), variable: "CRED_${k}")
    }

    withCredentials(bindings) {
        try {
            // ---- resolve every value (plain env + credentials) ----
            def vals = [:]
            for (k in t.env.keySet()) { vals[k] = (t.env[k] == null ? '' : t.env[k].toString()) }
            for (k in credKeys) { vals[k] = env."CRED_${k}" ?: '' }
            // auto-generated shared secrets (explicit env/creds of the same name win)
            for (sc in t.secrets) {
                def grpVals = sharedSecrets[sc.group] ?: [:]
                for (k in sc.keys) {
                    if (!(vals[k] ?: '').trim()) {
                        if (!grpVals.containsKey(k)) { error "[${t.id}] shared secret ${k} was not resolved." }
                        vals[k] = grpVals[k]
                    }
                }
            }

            for (k in t.minLen.keySet()) {
                if ((vals[k] ?: '').length() < (t.minLen[k] as int)) {
                    error "[${t.id}] ${k} must be at least ${t.minLen[k]} characters."
                }
            }
            for (k in t.required) {
                if (!(vals[k] ?: '').trim()) { error "[${t.id}] required value ${k} is empty." }
            }

            // ---- pre-flight dirs ----
            for (rawDir in t.preDirs) {
                def d = renderTokens(rawDir, vals)
                if (!(d ==~ /^\/[A-Za-z0-9_.\/\-]+$/)) { error "[${t.id}] unsafe preDir '${d}'" }
                sh "${SSH} ${target} 'sudo -n mkdir -p ${d}'"
            }

            // ---- remote working dir + uploads ----
            sh "${SSH} ${target} 'mkdir -p ${rdir} && chmod 700 ${rdir}'"
            def uploads = [t.script] + t.files
            for (f in uploads) {
                sh "${SCP} ${env.SCRIPTS_DIR}/${f} ${target}:${rdir}/${f}"
            }

            // ---- optional cross-host file copies (host A -> Jenkins -> this host) ----
            def flags = t.flags ?: ''
            for (f in t.fetch) {
                if (fetchThenPush(SSH, SCP, f.fromHost, f.fromPath, t.host, f.toPath, t.id, f.sudo ? true : false)) {
                    if (f.flag) { flags += ' ' + f.flag }
                } else if (f.required) {
                    error "[${t.id}] could not copy ${f.fromPath} from ${f.fromHost} (is the first node installed and does SSH_USER have sudo there?)"
                } else {
                    echo "WARNING [${t.id}]: could not fetch ${f.fromPath} from ${f.fromHost}; continuing without it."
                }
            }

            // ---- generated run.sh (holds secrets; chmod 600; deleted after run) ----
            def exports = (t.mode == 'env') ? (vals.keySet() as List) : t.exportEnv
            def sb = new StringBuilder()
            sb << "#!/bin/bash\n"
            for (k in exports) {
                if (!(k ==~ /^[A-Za-z_][A-Za-z0-9_]*$/)) { error "[${t.id}] invalid env var name '${k}'" }
                sb << "export ${k}=${shq(vals[k] ?: '')}\n"
            }
            if (t.mode == 'env') { sb << "export AUTOMATED=1\n" }
            sb << "cd \"\$(dirname \"\$0\")\"\n"
            if (t.maskLogs) {
                // keep the script's exit code, but never print "...PASSWORD=value" lines to the build log
                sb << "set -o pipefail\n"
                sb << "bash ./${t.script} ${flags} 2>&1 | sed -u -E 's/(PASSWORD=).*/\\1********/'\n"
            } else {
                sb << "exec bash ./${t.script} ${flags}\n"
            }
            sh "mkdir -p ${ldir}"
            writeFile(file: "${ldir}/run.sh", text: sb.toString())
            sh "chmod 600 ${ldir}/run.sh"
            sh "${SCP} ${ldir}/run.sh ${target}:${rdir}/run.sh"

            // ---- stdin answers (legacy mode) ----
            def stdinFile = '/dev/null'
            if (t.mode == 'stdin') {
                def lines = []
                for (l in t.stdin) { lines << renderTokens(l.toString(), vals) }
                stdinFile = "${ldir}/answers.txt"
                writeFile(file: stdinFile, text: lines.join('\n') + '\n')
                sh "chmod 600 ${stdinFile}"
            }

            // ---- run ----
            echo "[${t.id}] running ${t.script} on ${t.host} ..."
            sh "${SSH} ${target} 'sudo -n bash ${rdir}/run.sh' < ${stdinFile}"
            echo "[${t.id}] finished OK."
        } finally {
            // secrets must never be left behind, success or failure
            sh(script: "${SSH} ${target} 'rm -f ${rdir}/run.sh'", returnStatus: true)
            for (f in t.fetch) {
                // copied files that hold keys/passwords (e.g. OpenSearch certificate bundles)
                if (f.cleanup) { sh(script: "${SSH} ${target} 'sudo -n rm -f ${f.toPath}'", returnStatus: true) }
            }
            sh "rm -rf ${ldir} || true"
        }
    }
}

// Copies srcHost:srcPath -> Jenkins workspace -> dstHost:dstPath. Must be called inside
// withCredentials (needs $SSH_KEY). useSudo reads the source with 'sudo cat' (root-only files).
// Returns false (never throws) if anything fails.
def fetchThenPush(String SSH, String SCP, String srcHost, String srcPath, String dstHost, String dstPath, String taskId, boolean useSudo) {
    def tmp = ".deploy/${taskId}/fetched.tmp"
    try {
        if (!(srcPath ==~ /^\/[A-Za-z0-9_.\/\-]+$/)) {
            echo "fetchThenPush: unsafe source path '${srcPath}'"
            return false
        }
        sh "mkdir -p .deploy/${taskId}"
        def rc
        if (useSudo) {
            rc = sh(script: "umask 077; ${SSH} ${params.SSH_USER}@${srcHost} 'sudo -n cat ${srcPath}' > ${tmp}", returnStatus: true)
        } else {
            rc = sh(script: "${SCP} ${params.SSH_USER}@${srcHost}:${srcPath} ${tmp}", returnStatus: true)
        }
        if (rc != 0) { return false }
        sh "chmod 600 ${tmp}"
        sh "${SCP} ${tmp} ${params.SSH_USER}@${dstHost}:${dstPath}"
        return true
    } catch (Exception e) {
        echo "fetchThenPush error: ${e.message}"
        return false
    } finally {
        sh "rm -f ${tmp} || true"
    }
}
