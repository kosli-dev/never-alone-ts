# Proxy workaround

In DB the default proxy configuration makes the `kosli attest pullrequest github` fail
with `Error: Post "https://api.github.com/graphql": authenticationrequired`

We can workaround by running a local proxy.

## Install python proxy server px

### Create px configuration file

```bash
mkdir -p ~/.config/px
touch ~/.config/px/px.ini
```

Add the following content to `~/.config/px/px.ini`

```text
[proxy]
server = <fqn-proxy-server-name:port> 
listen = 3128
```

### Install and activate px

```bash
cd
python3 -m venv ~/venvs/px
source ~/venvs/px/bin/activate
pip install px-proxy
px
```

Expected output showing `px` is running: `Serving at 127.0.0.1:3128 proc MainProcess`
Leave px running for now

### Testing

- Open a new terminal

- Requirements:

```text
# The member access token
export KOSLI_API_TOKEN=[your-own-token-value]
# Metrics Org
export KOSLI_ORG=Deutsche-Bank-Metrics
# Github token
export GITHUB_TOKEN=[your-own-github-token] # remember to authorize it for github-org f708-zp9u
```

Running the command below will fail:

```bash
kosli attest pullrequest github \ 
    --name pr \ 
    --github-token "${GITHUB_TOKEN}" \ 
    --trail < commit-sha > \  
    --commit < commit-sha > \ 
    --github-org < github-org > \ 
    --repository < repo name >  \ 
    --flow < flow-name > \ 
    --repo-root < relative path to repository > 
```

Override proxy to our local

`export HTTPS_PROXY=http://localhost:3128`

and run `kosli attest pullrequest github` again, this time it should be successful

### Clean up

Switch to the terminal with px:

```bash
CTRL+C # to terminate the px process
deactivate # to terminate the python virtual environment
```
