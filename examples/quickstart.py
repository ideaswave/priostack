from priostack.client import ACNClient

def main():
    # 1. Initialisation
    acn = ACNClient()

    # 2. Autonomously Register Agent (No API Key Required)
    print("1. Enregistrement de l'agent...")
    acn_key = acn.register(display_name="my-ai-agent")
    print(f"Clé ACN obtenue : {acn_key}")

    # 3. Connexion & Obtention du Session ID
    session_id = acn.connect(token=acn_key)
    print(f"Session ID actif : {session_id}")

    # 4. Création d'un espace de mémoire
    space = acn.create_space(display_name="prod-agent-memory")
    print(f"Espace de mémoire créé : {space}")

    # 5. Stockage d'une règle ou observation
    acn.store(
        space_id="prod-agent-memory",
        content="L'utilisateur a validé le workflow d'exécution numéro #402.",
        object_type="declaration"
    )
    print("Mémoire stockée avec succès sur Priostack ACN !")

if __name__ == "__main__":
    main()
