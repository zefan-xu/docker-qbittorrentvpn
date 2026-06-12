FROM python:3.14-alpine@sha256:003970a263347645cd23d4f90929ad16ba7ce7d808ee4674ffcc93cb21cc289f

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
