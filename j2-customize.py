def j2_environment_params():
    """ Extra parameters for the Jinja2 Environment """
    # Jinja2 Environment configuration
    # http://jinja.pocoo.org/docs/2.10/api/#jinja2.Environment
    return dict(
        # Remove whitespace around blocks
        trim_blocks=True,
        lstrip_blocks=True,
    )
