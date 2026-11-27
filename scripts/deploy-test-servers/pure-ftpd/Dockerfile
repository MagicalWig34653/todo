# Test-only FTP/FTPS server for the deploy transport tests (card 354ADE12). Never used in production.
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends pure-ftpd openssl && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 21 30000-30009
ENTRYPOINT ["/entrypoint.sh"]
