# ===========================================================================
#  nomad_server — atajos del repositorio
# ===========================================================================
#  Este Makefile NO configura el servidor: solo opera sobre el repositorio de
#  documentación (validaciones, ayuda, preparación local). La configuración del
#  servidor se hace ejecutando los scripts de scripts/ en el propio servidor,
#  siguiendo los capítulos de docs/.
# ===========================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := ayuda

# ---------------------------------------------------------------------------

.PHONY: ayuda
ayuda: ## Muestra esta ayuda
	@echo ""
	@echo "  nomad_server — montaje reproducible de un servidor Debian"
	@echo ""
	@echo "  Objetivos disponibles:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[1;34m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Empieza por:  docs/00_planificacion.md"
	@echo ""

.PHONY: init
init: ## Crea config/servidor.env a partir de la plantilla
	@if [[ -f config/servidor.env ]]; then \
		echo "[=]     config/servidor.env ya existe; no se sobrescribe."; \
	else \
		cp config/servidor.env.example config/servidor.env; \
		chmod 600 config/servidor.env; \
		echo "[OK]    Creado config/servidor.env (permisos 600)."; \
		echo "[INFO]  Edítalo antes de ejecutar cualquier script."; \
	fi

.PHONY: check
check: ## Valida el repositorio completo (documentación + scripts)
	@scripts/verificar_repositorio.sh

.PHONY: check-scripts
check-scripts: ## Solo valida los scripts (sintaxis, shellcheck, --help)
	@scripts/verificar_repositorio.sh --solo scripts

.PHONY: check-docs
check-docs: ## Solo valida la documentación (plantilla, variables, enlaces)
	@scripts/verificar_repositorio.sh --solo docs

.PHONY: check-secretos
check-secretos: ## Busca secretos que se hayan colado en el repositorio
	@scripts/verificar_repositorio.sh --solo secretos

.PHONY: indice
indice: ## Lista los capítulos en su orden de ejecución
	@echo ""
	@for f in docs/[0-9]*.md; do \
		printf "  \033[1;34m%-38s\033[0m %s\n" "$$f" "$$(grep -m1 '^# ' "$$f" | sed 's/^# //')"; \
	done
	@echo ""

.PHONY: herramientas
herramientas: ## Indica cómo instalar las herramientas de validación opcionales
	@echo ""
	@echo "  Herramientas usadas por 'make check' (todas opcionales salvo bash):"
	@echo ""
	@echo "    shellcheck  → análisis estático de los scripts"
	@echo "                  Debian/Ubuntu: sudo apt install shellcheck"
	@echo "                  Fedora:        sudo dnf install ShellCheck"
	@echo "    lychee      → verificación de enlaces en la documentación"
	@echo "                  cargo install lychee   (o descarga del release)"
	@echo ""
