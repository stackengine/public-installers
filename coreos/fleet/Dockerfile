FROM  ubuntu:14.04
MAINTAINER Boyd Hemphill <boyd@stackengine.com>

# Create a place to work
RUN mkdir /stackengine
WORKDIR /stackengine

# Create a place to store the data
RUN mkdir /stackenginedata

# We will need curl for communicating with etcd 
RUN apt-get update -yqq && apt-get install -yqq curl gawk

# Responses from etcd will come back as json.
# Parsing json in bash sucks.
# JSON.awk is a nice tool for the purpose
# https://github.com/step-/JSON.awk
ADD https://raw.githubusercontent.com/step-/JSON.awk/master/JSON.awk \
	/stackengine/ 
RUN chmod +x /stackengine/JSON.awk

# Grab the stackengine binary
ADD https://s3.amazonaws.com/stackengine-controller/linux64/stackengine \ 
	/stackengine/
RUN chmod +x /stackengine/stackengine

# Add the startup script
ADD startup.sh	\
	/stackengine/ 
RUN chmod +x /stackengine/startup.sh

# Expose the ports we need for the controller to communicate across the mesh
# and serve the admin interface
EXPOSE 8000 8001 8002

# Set and explain the entrypoint
ENTRYPOINT ["/stackengine/startup.sh"]

