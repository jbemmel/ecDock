#
# ecDock install container
#
# to build: sudo docker build -t ecdock/install .

FROM ubuntu
MAINTAINER ecDock team <jvb127@gmail.com>

ENV http_proxy http://global.proxy.alcatel-lucent.com:8000
ENV https_proxy http://global.proxy.alcatel-lucent.com:8000

RUN apt-get update && apt-get install -y wget dialog ssh tar
ADD ecDock.tar.gz /install/
ADD install_ecDock.sh /

ENTRYPOINT ["/install_ecDock.sh"]
