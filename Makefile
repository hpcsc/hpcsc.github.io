SHELL = /bin/bash
HUGO_VERSION = 0.124.1

BINARY_OS := $(shell uname | sed 's/Darwin/macOS/')

install_hugo:
	mkdir -p ./bin
	curl --fail -L https://github.com/gohugoio/hugo/releases/download/v$(HUGO_VERSION)/hugo_$(HUGO_VERSION)_$(BINARY_OS)-64bit.tar.gz | \
		tar --overwrite -C ./bin -xvzf - hugo

clean:
	rm -rf public

restore_theme:
	git submodule update --recursive

update_theme:
	git submodule update --remote

build: clean restore_theme
	./bin/hugo --config config.toml,config.prod.toml

start:
	./bin/hugo --config config.toml,config.dev.toml server

gen_highlight_css:
	./bin/hugo gen chromastyles --style=dracula | tee ./static/css/highlight.css
