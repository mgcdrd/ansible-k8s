.DEFAULT_GOAL := help

# Local overrides:
# ../../ansible-local.mk
-include ../../ansible-local.mk

VENV ?= .venv
PYTHON ?= python3
ANSIBLE_GALAXY ?= $(VENV)/bin/ansible-galaxy
ANSIBLE_LINT ?= $(VENV)/bin/ansible-lint
MOLECULE ?= $(VENV)/bin/molecule

.PHONY: help venv setup devrepos install lint syntax clean

help:
	@echo "Available targets"
	@echo "  make setup       Create dev environment"
	@echo "  make devinstall  Install Dev Ansible dependencies"
	@echo "  make install     Install Ansible dependencies"
	@echo "  make lint        Run ansible-lint"
	@echo "  make syntax      Check playbook syntax"
	@echo "  make test        Run Molecule tests"
	@echo "  make clean       Remove generated files"

venv:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip

setup: venv
	$(VENV)/bin/pip install \
		ansible \
		ansible-lint \
		molecule \
		molecule-docker

devinstall: setup
	cp collections/requirements.yml collections/requirements.yml.local
	/usr/local/bin/yq -i '(.collections[] | select(.name == "mgcdrd.infrabase") | .source) = strenv(INFRA_BASE_URL)' collections/requirements.yml.local
	/usr/local/bin/yq -i '(.collections[] | select(.name == "mgcdrd.infrasvc") | .source) = strenv(INFRA_SVC_URL)' collections/requirements.yml.local
	$(ANSIBLE_GALAXY) collection install \
		-r collections/requirements.yml.local \
		-p collections

install: setup
	$(ANSIBLE_GALAXY) collection install \
		-r collections/requirements.yml \
		-p collections

lint:
	$(ANSIBLE_LINT)

syntax:
	$(VENV)/bin/ansible-playbook \
		--syntax-check \
		site.yml

test:
	$(MOLECULE) test

clean:
	rm -rf $(VENV)
	rm -rf .molecule
