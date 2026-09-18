FROM python:3.14-alpine@sha256:6f945b4c17e0a1ee862ada29a91406bc86d58180ce7de902d8de1f30730e3760

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
