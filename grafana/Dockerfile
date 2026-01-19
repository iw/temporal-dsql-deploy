# Custom Grafana image with pre-configured datasources and dashboards
# for Temporal DSQL deployment (docker-compose)
#
# Build: docker build -t temporal-grafana:latest grafana/
# 
# Environment variables (set in docker-compose.yml):
#   PROMETHEUS_URL - Prometheus/Mimir endpoint (default: http://mimir:9009/prometheus)
#   AWS_REGION - AWS region for CloudWatch (optional)

FROM grafana/grafana-oss:latest

# Copy provisioning configuration
COPY provisioning/ /etc/grafana/provisioning/

# Copy dashboards
COPY server/ /var/lib/grafana/dashboards/server/
COPY dsql/ /var/lib/grafana/dashboards/dsql/

# Copy entrypoint script for environment variable substitution
COPY entrypoint.sh /entrypoint.sh

# Set ownership and permissions
USER root
RUN chown -R grafana:root /etc/grafana/provisioning /var/lib/grafana/dashboards && \
    chmod +x /entrypoint.sh
USER grafana

ENTRYPOINT ["/entrypoint.sh"]
