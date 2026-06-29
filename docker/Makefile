RESTART = --restart unless-stopped
#  External port the container is published on.  The MCP server inside
#  the container always listens on 3410; this maps it onto the host.
PORT    = 3410

PUBLISH = --publish=$(PORT):3410
DOPTS   = $(PUBLISH)
IMG     = mcp-help
NAME    = mcp-help

all:
	@echo "Targets"
	@echo
	@echo "image            Build the $(IMG) image"
	@echo "run              Run the image (detached)"
	@echo "restart          Stop, remove and re-run the container"
	@echo "stop             Stop and remove the container"
	@echo "logs             Tail container logs"
	@echo "bash             Shell into a one-off container"
	@echo
	@echo "update-swipl     Rebuild swipl (and MCP) layers"
	@echo "update-mcp       Rebuild the MCP layer only"

image::
	docker build -t $(IMG) .

run:
	docker run --name=$(NAME) -d $(RESTART) $(DOPTS) $(IMG)

stop:
	-docker stop $(NAME)
	-docker rm   $(NAME)

restart: stop run

logs:
	docker logs -f $(NAME)

bash:
	docker run -it --rm --entrypoint=/bin/bash $(DOPTS) $(IMG)

update-swipl:
	sed -i 's/SWIPL_VERSION=.*/SWIPL_VERSION="'"$$(date)"'"/' Dockerfile
	$(MAKE) image

update-mcp:
	sed -i 's/MCP_VERSION=.*/MCP_VERSION="'"$$(date)"'"/' Dockerfile
	$(MAKE) image
