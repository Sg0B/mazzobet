Aggiungi un aiuto sulle quote nel form di creazione scommessa (CreateSheet.tsx).

Regola già esistente (non cambiarla): con le quote in centesimi A (SÌ) e B (NO) deve valere 100*(A+B) >= A*B.
Data una quota, il massimo dell'altra è: maxAltra = min(1000, floor(100*A / (A - 100))) centesimi.
Esempi: SÌ 2,50 → NO max 1,66. SÌ 2,00 → NO max 2,00. SÌ 10,00 → NO max 1,11.

Comportamento:
1. Quando una delle due quote è valida (tra 1,10 e 10,00), sotto o dentro il campo dell'altra mostra in grigio chiaro e piccolo "MAX 1,66" (formato italiano, due decimali, virgola). Se l'altra quota è vuota, usa il testo come placeholder o riga di aiuto sotto il campo.
2. Se entrambe le quote sono compilate, ogni campo mostra il proprio massimo calcolato sull'altra quota. Se la coppia viola la regola, il testo diventa rosso e il messaggio d'errore dice il numero preciso: "Con SÌ a 2,50 il NO può arrivare al massimo a 1,66."
3. Tocco sul "MAX 1,66" compila il campo con quel valore (comodo da telefono).
4. Calcola tutto in interi (centesimi), niente float, e riusa la stessa funzione di validazione che già usa il form, senza duplicare la formula.
5. Se la quota inserita è fuori range (sotto 1,10 o sopra 10,00), non mostrare niente.
6. Nessuna modifica al server: il controllo lato SQL resta come è.

Test: SÌ 2,50 mostra NO MAX 1,66; con NO 1,67 il bottone è bloccato col messaggio; SÌ 1,10 mostra NO MAX 10,00 (tetto); tocco su MAX compila il campo; funziona su schermo stretto (360px).