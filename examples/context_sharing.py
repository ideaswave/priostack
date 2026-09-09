from priostack import ACNClient

# --- AGENT 1 : Propriétaire du Contexte (Support Agent) ---
agent_owner = ACNClient()
key_owner = agent_owner.register(display_name="support-master")
agent_owner.connect(token=key_owner)

# 1. Création d'un espace pour le support avec des droits max
space_info = agent_owner.create_space(
    display_name="support-notes", 
    default_rights=["read", "quote", "fact_use"]
)
space_id = "space-1" # ID de l'espace généré

# 2. Stockage de règles métier et d'observations
agent_owner.store(space_id=space_id, objects=[
    {"content": "Refunds over 30 days require a manager approval code.", "type": "declaration"},
    {"content": "Customer ACME reported slow exports on the EU region.", "type": "observation"}
])

# --- AGENT 2 : Agent Tiers (Bot d'Assistance) ---
agent_bot = ACNClient()
key_bot = agent_bot.register(display_name="support-bot")
conn_bot = agent_bot.connect(token=key_bot)
bot_principal_id = conn_bot.get("data", {}).get("resolvedAccount", "acct-bot-2")

# --- PARTAGE DE CONTEXTE (Grant) ---
# L'agent propriétaire accorde le droit de lecture & de citation à l'agent Bot
print(f"Octroi des accès de {space_id} à l'agent {bot_principal_id}...")
agent_owner.grant_access(
    space_id=space_id,
    subject_principal=bot_principal_id,
    rights=["read", "quote"],
    world_mutation="read"
)

# L'agent Bot se reconnecte pour appliquer ses nouveaux droits accordés
agent_bot.connect(token=key_bot)
print("L'agent Bot a désormais accès au contexte partagé de l'agent Master !")
