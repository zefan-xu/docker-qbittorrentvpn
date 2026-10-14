FROM python:3.15-alpine@sha256:ff4d3c9b1a48f646eedd93182aaea385c7a5452f4c8a8cd7cef686babacf4928

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
