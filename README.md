# Maailma - Sään, Ajan ja Eventtien Hallinta

## Kuvaus
**Maailma** = Sään, ajan ja eventtien hallintaan

**Ominaisuudet:**
- Sään hallinta (jäädytys, syklit, sademäärä, lumi maahan)
- Ajan hallinta (manuaalinen, pikavalinnat, reaaliaikasynkronointi)
- Erikoistapahtumat: tulva, maanjäristys, säkkisumu, lumimyrsky, halloween
- Hypotermia/selviytyminen kylmässä vedessä
- Sähkökatko (sammuta valot)
- Hallintapaneeli komennolla `/maailma`

## Konfiguraatio
- Lisää server.cfg `add_ace group.admin weather.admin allow`
tai oma admin groupin arvo jne
- Configista yksittäiset käyttäjät, joilla oikeus hallintapaneeliin

- **Sääasetukset**: Aloitussää, vaihtoväli, lumi maahan, säätyyppien todennäköisyydet
- **Selviytyminen**: Hypotermia
- **Tulva**: Hukkumisaika, sireenipaikat
- **Aika**: Päivän pituus, reaaliaikasynkronointi

### Paneelin Toiminnot
1. **Etusivu**: Nykytila, hypotermia toggle
2. **Sää**: Sääjäädytys, perus/lumi-syklit, sademäärä, lumi maahan
3. **Aika**: Jäädytys, manuaali/pikavalinnat, reaaliaikasync
4. **Tilat & Eventit**:
   - **Vedenpaisumus**: Korkeus (1-100m), nousunopeus, 15min ajastin, myrsky/sireenit/varoitus
   - **Maanjäristys**: Voimakkuus, varoitus/sireenit
   - **Säkkisumu**: Tiheys (10-100%)
   - **Lumimyrsky**: Voimakkuus, lumi maahan
   - **Halloween**: Myrskyvaihtoehto
   - **Blackout**: Valot pois (kaikki + autot)

Huom! Scriptin tekemisessä käytetty tekoälyä.
