include .env
export $(shell sed 's/=.*//' .env)

deploy_index_fund:
	@echo "Deploying IndexFund"
	@forge script script/Deployer.s.sol:DeployIndexFund --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast --verify -vvvvv
	@echo "Deployment completed!"

check_index_fund:
	@echo "Checking IndexFund deployment"
	@forge script script/Deployer.s.sol:DeployIndexFund --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) -vvvv
	@echo "Check completed!" 