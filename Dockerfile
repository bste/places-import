FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      osmium-tool osm2pgsql postgresql-client python3 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY import.sh places.lua post.sql swap.sql poly2sql.py /import/
RUN chmod +x /import/import.sh /import/poly2sql.py

VOLUME /data
ENTRYPOINT ["/import/import.sh"]
