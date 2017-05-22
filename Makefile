.DEFAULT_GOAL := help
.PHONY: help deploy development build underline

help: ## (default), display the list of make commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# Helpers

guard-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

# Content

build/content.json: guard-CONTENTFUL_SPACE guard-CONTENTFUL_KEY
	@mkdir -p $(dir $@)
	node_modules/.bin/cswg sync -s $(CONTENTFUL_SPACE) -t $(CONTENTFUL_KEY) > $@

# Stylesheets

build/css/%.min.css: build/css/%.css
	node_modules/.bin/uglifycss $< > $@

build/css/%.css: src/scss/%.scss
	@mkdir -p $(dir $@)
	node_modules/.bin/node-sass $< $@

# JavaScript

build/js/%.min.js: build/js/%.js
	@mkdir -p $(dir $@)
	./node_modules/.bin/uglifyjs $< -o $@

build/js/%.js: src/js/%.js
	@mkdir -p $(dir $@)
	./node_modules/.bin/browserify $< -o $@ -t [ babelify ]

# HTML

build/templates: src/**/*.html node_modules/@coderbyheart/underline/templates/*.html node_modules/@coderbyheart/underline/templates/**/*.html
	@mkdir -p $@
	cp -r node_modules/@coderbyheart/underline/templates/* $@
	cp -r src/* $@

build/fonts:
	@mkdir -p $@
	cp node_modules/@coderbyheart/underline/dist/fonts/* $@

build/js/coderbyheart.min.js: build/js/coderbyheart.js
	@mkdir -p $(dir $@)
	./node_modules/.bin/uglifyjs $< -o $@

build/coderbyheart.js: src/coderbyheart.js
	@mkdir -p $(dir $@)
	./node_modules/.bin/browserify $< -o $@ -t [ babelify ]

underline: build/css/underline.min.css build/js/coderbyheart.min.js build/fonts build/templates

# DEPLOY

AWS_REGION ?= eu-central-1
AWS_BUCKET ?= lets-work-remote.de
S3_CFG := /tmp/.s3cfg-$(AWS_BUCKET)
VERSION ?= $(shell node -e "process.stdout.write(require('./package.json').version)")
DEPLOY_TIME ?= $(shell date +%s)

deploy: build guard-AWS_SECRET_ACCESS_KEY guard-AWS_ACCESS_KEY ## Deploy to AWS S3
	# Build
	make clean
	ENVIRONMENT=production make -B build

	# Create s3cmd config
	@echo $(S3_CFG)
	@echo "[default]" > $(S3_CFG)
	@echo "access_key = $(AWS_ACCESS_KEY)" >> $(S3_CFG)
	@echo "secret_key = $(AWS_SECRET_ACCESS_KEY)" >> $(S3_CFG)
	@echo "bucket_location = $(AWS_REGION)" >> $(S3_CFG)

	# Create bucket if not exists
	@if [[ `s3cmd -c $(S3_CFG) ls | grep s3://$(AWS_BUCKET) | wc -l` -eq 1 ]]; then \
		echo "Bucket exists"; \
	else \
		s3cmd -c $(S3_CFG) mb s3://$(AWS_BUCKET); \
		s3cmd -c $(S3_CFG) ws-create s3://$(AWS_BUCKET)/ --ws-index=index.html --ws-error=404.html; \
	fi

	# Upload
	s3cmd -c $(S3_CFG) \
		sync -P -M --no-mime-magic --delete-removed build/ s3://$(AWS_BUCKET)/

	# Expires 10 minutes for html files
	s3cmd -c $(S3_CFG) \
		modify --recursive \
		--add-header=Cache-Control:public,max-age=600 \
		--remove-header=Expires \
		--add-header=x-amz-meta-version:$(VERSION)-$(DEPLOY_TIME) \
		--exclude "*" --include "*.html" --include "*.txt" \
		s3://$(AWS_BUCKET)/

	# Expires 1 year for everything else
	s3cmd -c $(S3_CFG) \
		modify --recursive \
		--add-header=Cache-Control:public,max-age=31536000 \
		--remove-header=Expires \
		--add-header=x-amz-meta-version:$(VERSION)-$(DEPLOY_TIME) \
		--exclude "*.html" --exclude "*.txt" \
		s3://$(AWS_BUCKET)/

# Cleanup

clean:
	rm -rf build

# MAIN

development: ## Build for development environment
	ENVIRONMENT=development make build

build: build/content.json build/templates build/js/coderbyheart.min.js underline guard-CONTENTFUL_LOCALE ## Build for production environment
	node_modules/.bin/cswg build -c $< -v $(VERSION) -l $(CONTENTFUL_LOCALE) -e production -t build/templates
