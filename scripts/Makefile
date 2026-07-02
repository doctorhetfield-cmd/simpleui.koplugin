ZIP_NAME = simpleui.koplugin.zip
ROOT_DIR = simpleui.koplugin

.PHONY: clean build

build:
	@echo ">> Building $(ZIP_NAME)"
	@rm -f ../$(ZIP_NAME)
	@cd ../.. && zip -r $(ROOT_DIR)/$(ZIP_NAME) $(ROOT_DIR) \
		--exclude "$(ROOT_DIR)/.git/*" \
		--exclude "$(ROOT_DIR)/.github/*" \
		--exclude "$(ROOT_DIR)/scripts/*" \
		--exclude "$(ROOT_DIR)/.DS_Store" \
		--exclude "$(ROOT_DIR)/.gitignore" \
		--exclude "$(ROOT_DIR)/CONTRIBUTING.md" \
		--exclude "$(ROOT_DIR)/LICENSE" \
		--exclude "$(ROOT_DIR)/README.md" \
		--exclude "$(ROOT_DIR)/$(ZIP_NAME)" \
		--exclude "$(ROOT_DIR)/icons/custom/*" \
		--exclude "$(ROOT_DIR)/desktop_modules/custom_quotes/*"
	@echo ">> Done!"

clean:
	@rm -f ../$(ZIP_NAME)
