FROM python:3.14-alpine@sha256:0b07f06aa553707ded79e952a43fbb63506a806205151812d6dc2a0f76f3ab80

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
