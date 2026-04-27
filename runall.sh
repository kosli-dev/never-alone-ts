 export KOSLI_ORG="sofus-test"
 export $(grep -v '^#' .env | xargs)

npm install          # Install dependencies
npm run build        # Compile TypeScript → dist/
npm test             # Run Jest unit tests
docker run --rm -v "$(pwd)":/work openpolicyagent/opa test /work/four-eyes.rego /work/four-eyes_test.rego -v    # Run Rego policy tests (requires Docker)

bash simulate-granular.sh  # Simulate granular events and test the CLI