.PHONY: test rebuild

test:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

rebuild:
	./rebuild.sh "$(LOCK)" --output "$(or $(OUTPUT),out/rebuild)"
