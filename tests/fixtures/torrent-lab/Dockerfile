FROM python:3.14-alpine@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
