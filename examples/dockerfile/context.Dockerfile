FROM python:3.11.9-bullseye@sha256:64da8e5fd98057b05db01b49289b774e9fa3b81e87b4883079f6c31fb141b252

ARG DEBIAN_FRONTEND=noninteractive

ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LANGUAGE=C.UTF-8

ADD /app /app

WORKDIR /app

RUN pip install --root-user-action=ignore -r requirements.txt

CMD ["/app/src/say.py"]