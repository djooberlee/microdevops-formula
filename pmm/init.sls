{% if pillar['pmm'] is defined %}

docker_install_00:
  file.directory:
    - name: /etc/docker
    - mode: 700

docker_install_01:
  file.managed:
    - name: /etc/docker/daemon.json
    - contents: |
        {"iptables": false}
docker_install_1:
  pkgrepo.managed:
    - humanname: Docker CE Repository
    - name: deb [arch=amd64] https://download.docker.com/linux/{{ grains['os']|lower }} {{ grains['oscodename'] }} stable
    - file: /etc/apt/sources.list.d/docker-ce.list
    - key_url: https://download.docker.com/linux/{{ grains['os']|lower }}/gpg

docker_install_2:
  pkg.installed:
    - refresh: True
    - reload_modules: True
    - pkgs: 
        - docker-ce: '{{ pillar['pmm']['docker-ce_version'] }}*'
        - python3-pip
                
docker_pip_install:
  pip.installed:
    - name: docker-py >= 1.10
    - reload_modules: True

docker_install_3:
  service.running:
    - name: docker

docker_install_4:
  cmd.run:
    - name: 'systemctl restart docker'
    - onchanges:
        - file: /etc/docker/daemon.json

acme_cert:
  cmd.run:
    - shell: /bin/bash
    - name: "/opt/acme/home/{{ pillar["pmm"]["acme_account"] }}/verify_and_issue.sh percona_pmm {{ pillar["pmm"]["servername"] }}"



{%- for domain in pillar['pmm']['domains'] %}
    {%- set i_loop = loop %}
    {%- for instance in domain['instances'] %}


percona_pmm_etc_dir_{{ loop.index }}_{{ i_loop.index }}:
  file.directory:
    - name: /opt/pmm/{{ domain['name'] }}/{{ instance['name'] }}/etc
    - mode: 755
    - makedirs: True


nginx_create_conf_pmm:
  file.managed:
    - name: /opt/pmm/{{ domain['name'] }}/pmm.conf
    - contents: |
        #gzip on;
        #etag on;
        
        upstream managed-grpc {
          server 127.0.0.1:7771;
          keepalive 32;
        }
        upstream managed-json {
          server 127.0.0.1:7772;
          keepalive 32;
          keepalive_requests 100;
          keepalive_timeout 75s;
        }
        
        upstream qan-api-grpc {
          server 127.0.0.1:9911;
          keepalive 32;
        }
        upstream qan-api-json {
          server 127.0.0.1:9922;
          keepalive 32;
          keepalive_requests 100;
          keepalive_timeout 75s;
        }
        
        server {
          listen 80;
          listen 443 ssl http2;
          server_name {{ pillar["pmm"]["servername"] }};
          server_tokens off;
        
          # workaround CVE-2017-7529
          max_ranges 1;
          # allow huge requests
          large_client_header_buffers 128 64k;
        
          client_max_body_size 10m;


          ssl_certificate /opt/acme/cert/{{ pillar["pmm"]["servername"] }}/fullchain.cer;
          ssl_certificate_key /opt/acme/cert/{{ pillar["pmm"]["servername"] }}/{{ pillar["pmm"]["servername"] }}.key;

          #ssl_certificate /srv/nginx/certificate.crt;
          #ssl_certificate_key /srv/nginx/certificate.key;
          #ssl_trusted_certificate /srv/nginx/ca-certs.pem;
          #ssl_dhparam /srv/nginx/dhparam.pem;
        
        
          # Enable passing of the remote user's IP address to all
          # proxied services using the X-Forwarded-For header
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
          # Enable auth_request for all locations, including root
          # (but excluding /auth_request and /setup below).
          auth_request /auth_request;
        
          # Store the value of X-Must-Setup header of auth_request subrequest response in the variable.
          # It is used below in /auth_request.
          auth_request_set $auth_request_must_setup $upstream_http_x_must_setup;
        
          # nginx completely ignores auth_request subrequest response body.
          # We use that directive to send the same request to the same location as a normal request
          # to get a response body or redirect and return it to the client.
          # auth_request supports only 401 and 403 statuses; 401 is reserved for this configration,
          # and 403 is used for normal pmm-managed API errors.
          error_page 401 = /auth_request;
        
          # Internal location for authentication via pmm-managed/Grafana.
          # First, nginx sends request there to authenticate it. If it is not authenticated by pmm-managed/Grafana,
          # it is sent to this location for the second time (as a normal request) by error_page directive above.
          location /auth_request {
            internal;
        
            auth_request off;
        
            proxy_pass http://managed-json/auth_request;
        
            # nginx always strips body from authentication subrequests.
            # Overwrite Content-Length to avoid problems on Go side and to keep connection alive.
            proxy_pass_request_body off;
            proxy_set_header Content-Length 0;
        
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        
            # This header is set only for to the second request, not for the first subrequest.
            # That variable is set above.
            proxy_set_header X-Must-Setup $auth_request_must_setup;
        
            # Those headers are set for both subrequest and normal request.
            proxy_set_header X-Original-Uri $request_uri;
            proxy_set_header X-Original-Method $request_method;
          }
        
          # AWS setup wizard
          location /setup {
            auth_request off;
        
            alias /usr/share/pmm-server/installation-wizard-page;
            try_files $uri /index.html break;
          }
        
          # Grafana
          rewrite ^/$ $scheme://$http_host/graph/;
          rewrite ^/graph$ /graph/;
          location /graph {
            proxy_cookie_path / "/;";
            proxy_pass http://127.0.0.1:3000;
            rewrite ^/graph/(.*) /$1 break;
            proxy_read_timeout 600;
          }
        
          # Remove next lines if bug is fixed https://github.com/grafana/grafana/issues/27226
          rewrite ^/(user/password/send-reset-email)$ $scheme://$http_host/graph/$1;
          rewrite ^/(login)$ $scheme://$http_host/graph/$1; 
        
          # Remove next line if bug is fixed https://github.com/grafana/grafana/issues/27588
          rewrite ^/explore(.*)$ $scheme://$http_host/graph/explore$1;
        
          # Prometheus
          location /prometheus {
            proxy_pass http://127.0.0.1:9090;
            proxy_read_timeout 600;
          }
        
          # VictoriaMetrics
          location /victoriametrics/ {
            proxy_pass http://127.0.0.1:9090/prometheus/;
            proxy_read_timeout 600;
            client_body_buffer_size 10m;
          }
        
          # VMAlert
          location /prometheus/rules {
            proxy_pass http://127.0.0.1:8880/api/v1/groups;
            proxy_read_timeout 600;
          }
          location /prometheus/alerts {
            proxy_pass http://127.0.0.1:8880/api/v1/alerts;
            proxy_read_timeout 600;
          }
        
          # Alertmanager
          location /alertmanager {
            proxy_pass http://127.0.0.1:9093;
          }
        
          # Swagger UI
          rewrite ^/swagger/swagger.json$ /swagger.json permanent;
          rewrite ^(/swagger)/(.*)$ /swagger permanent;
          location /swagger {
            auth_request off;
            root /usr/share/pmm-server/swagger;
            try_files $uri /swagger-ui.html break;
          }
          # pmm-managed gRPC APIs
          location /agent. {
            grpc_pass grpc://managed-grpc;
            # Disable request body size check for gRPC streaming, see https://trac.nginx.org/nginx/ticket/1642.
            # pmm-managed uses grpc.MaxRecvMsgSize for that.
            client_max_body_size 0;
          }
          location /inventory. {
            grpc_pass grpc://managed-grpc;
          }
          location /management. {
            grpc_pass grpc://managed-grpc;
          }
          location /server. {
            grpc_pass grpc://managed-grpc;
          }
        
          # pmm-managed JSON APIs
          location /v1/ {
            proxy_pass http://managed-json/v1/;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
          }
        
          # qan-api gRPC APIs should not be exposed
        
          # qan-api JSON APIs
          location /v0/qan/ {
            proxy_pass http://qan-api-json/v0/qan/;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
          }
        
          # for minimal compatibility with PMM 1.x
          rewrite ^/ping$ /v1/readyz;
          rewrite ^/managed/v1/version$ /v1/version;
        
          # logs.zip in both PMM 1.x and 2.x variants
          rewrite ^/managed/logs.zip$ /logs.zip;
          location /logs.zip {
            proxy_pass http://managed-json;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
          }
        
          # This localtion stores static content for general pmm-server purposes.
          # Ex.: local-rss.xml - contains Percona's news when no internet connection.
          location /pmm-static {
            auth_request off;
            alias /usr/share/pmm-server/static;
          }
        
          # proxy requests to the Percona's blog feed
          # fallback to local rss if pmm-server is isolated from internet.
          # https://jira.percona.com/browse/PMM-6153
          location = /percona-blog/feed {
            auth_request off;
            proxy_ssl_server_name on;
        
        set $feed https://www.percona.com/blog/feed/;
        proxy_pass $feed;
        proxy_set_header User-Agent "$http_user_agent pmm-server/2.x";
        error_page 500 502 503 504 /pmm-static/local-rss.xml;
          }
        }

percona_pmm_config_{{ loop.index }}_{{ i_loop.index }}:
  file.managed:
    - name: /opt/pmm/{{ domain['name'] }}/{{ instance['name'] }}/etc/grafana.ini
    - user: root
    - group: root
    - mode: 644
    - contents: {{ instance['config'] | yaml_encode }}

percona_pmm_image_{{ loop.index }}_{{ i_loop.index }}:
  cmd.run:
    - name: docker pull {{ instance['image'] }}

percona_pmm_container_{{ loop.index }}_{{ i_loop.index }}:
  docker_container.running:
    - name: percona-{{ domain['name'] }}
    - user: root
    - image: {{ instance['image'] }}
    - detach: True
    - restart_policy: unless-stopped
    - publish:
        - 443:443/tcp
    - binds:
        - /opt/pmm/{{ domain['name'] }}/{{ instance['name'] }}/etc:/etc/grafana:rw
        - /opt/pmm/{{ domain['name'] }}/pmm.conf:/etc/nginx/conf.d/pmm.conf:rw
        - /opt/acme/cert/{{ domain['name'] }}:/opt/acme/cert/{{ domain['name'] }}:rw
    - watch:
        - /opt/pmm/{{ domain['name'] }}/{{ instance['name'] }}/etc/grafana.ini

dump_pmm_cron:
  cron.present:
    - name: docker exec -i percona-{{ domain['name'] }} /bin/bash -c "pg_dump --username postgres pmm-managed" > /var/pmm_backup/pmm-managed.sql
    - user: root
    - minute: 0
    - hour: 3
{%- endfor %}
  {%- endfor %}


dir_for_backups:
  file.directory:
    - name: /var/pmm_backup
    - user: root
    - mode: 755
    - makedirs: True

{% endif %}
