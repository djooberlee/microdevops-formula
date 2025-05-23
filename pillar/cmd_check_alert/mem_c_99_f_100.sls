{% if grains["osarch"] in ["arm64"] %}
  {%- set ruby_prefix = "source /usr/local/rvm/scripts/rvm && /usr/local/rvm/gems/ruby-2.4.10/bin" %}
{% else %}
  {%- set ruby_prefix = "/opt/sensu-plugins-ruby/embedded/bin" %}
{% endif %}
cmd_check_alert:
  memory:
    config:
      checks:
        memory-percent:
          cmd_override: {{ ruby_prefix }}/check-memory-percent.rb -w 99 -c 100
