{% if pillar['percona-valkey']['sentinel_conf'] is defined %}

percona_valkey_repo_keyringdir:
  file.directory:
    - name: /etc/apt/keyrings
    - user: root
    - group: root

percona_valkey_sentinel_repo:
{% if grains['os_family'] == 'Debian' %}
  pkg.installed:
    - pkgs:
      - gnupg2
      - curl
      - lsb-release
  cmd.run:
    - name: |
        curl -O https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        dpkg -i percona-release_latest.generic_all.deb
        percona-release enable valkey release
        apt-get update
    - cwd: /tmp
    - unless: test -f /etc/apt/sources.list.d/percona-valkey-release.list
{% else %}
  pkg.installed:
    - pkgs:
      - gnupg2
      - curl
  cmd.run:
    - name: |
        yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable valkey release
        yum update -y
    - unless: test -f /etc/yum.repos.d/percona-valkey-release.repo
{% endif %}

percona_valkey_sentinel_install:
  pkg.latest:
    - refresh: True
    - reload_modules: True
    - pkgs:
        - percona-valkey

percona_valkey_sentinel_config_dir:
  file.directory:
    - name: /etc/valkey
    - user: 0
    - group: 0
    - mode: 755

percona_valkey_sentinel_config:
  file.managed:
    - name: /etc/valkey/sentinel.conf
    - user: 0
    - group: 0
    - mode: 644
    - contents: {{ pillar['percona-valkey']['sentinel_conf'] | yaml_encode }}

percona_valkey_sentinel_systemd:
  file.managed:
    - name: /etc/systemd/system/valkey-sentinel.service
    - user: 0
    - group: 0
    - mode: 644
    - contents: |
        [Unit]
        Description=Valkey Sentinel
        After=network.target
        Documentation=https://valkey.io/topics/sentinel

        [Service]
        Type=notify
        ExecStart=/usr/bin/valkey-sentinel /etc/valkey/sentinel.conf --supervised systemd
        ExecStop=/bin/kill -s TERM $MAINPID
        PIDFile=/var/run/valkey/sentinel.pid
        TimeoutStopSec=0
        Restart=always
        User=valkey
        Group=valkey
        RuntimeDirectory=valkey
        RuntimeDirectoryMode=0755

        [Install]
        WantedBy=multi-user.target
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
        - file: /etc/systemd/system/valkey-sentinel.service

percona_valkey_sentinel_run:
  service.running:
    - name: valkey-sentinel
    - enable: True
    - watch:
        - file: /etc/valkey/sentinel.conf

percona_valkey_sentinel_restart:
  cmd.run:
    - name: systemctl restart valkey-sentinel
    - onchanges:
        - file: /etc/valkey/sentinel.conf
{% endif  %}
