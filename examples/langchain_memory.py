from langchain.agents import initialize_agent, AgentType
from langchain.chat_models import ChatOpenAI
from langchain.tools import tool
from priostack import ACNClient

# Initialisation du client ACN
acn_client = ACNClient()
acn_token = acn_client.register(display_name="langchain-agent")
session_id = acn_client.connect(token=acn_token)
space_id = acn_client.create_space(display_name="langchain-space")

@tool
def save_persistent_memory(fact: str) -> str:
    """Useful to store important facts, user preferences, or state updates for future sessions."""
    acn_client.store(space_id=space_id, content=fact, object_type="declaration")
    return f"Fact successfully stored in Priostack ACN: '{fact}'"

# Configuration de l'agent LangChain
llm = ChatOpenAI(model="gpt-4o", temperature=0)
tools = [save_persistent_memory]

agent = initialize_agent(
    tools,
    llm,
    agent=AgentType.ZERO_SHOT_REACT_DESCRIPTION,
    verbose=True
)

# Test d'exécution
if __name__ == "__main__":
    response = agent.run(
        "Remember that the user's primary programming language is Python."
    )
    print(response)
