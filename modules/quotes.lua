-- quotes.lua — Simple UI
-- Quote database for the Desktop "Quote of the Day" module.
-- Edit freely: add, remove or replace entries in the same format.
-- Format: { q = "Quote text.", a = "Author", b = "Book title (optional)" }
-- Entries are shown in shuffled order; the groups below are for maintenance only.
-- Keep each quote short enough to fit the module's three-line layout.

return {

    -- Reading and books
    { q = "A reader lives a thousand lives before he dies. The man who never reads lives only one.", a = "George R.R. Martin", b = "A Dance with Dragons" },
    { q = "I have always imagined that Paradise will be a kind of library.", a = "Jorge Luis Borges" },
    { q = "A book must be the axe for the frozen sea within us.", a = "Franz Kafka" },
    { q = "Books are mirrors: we only see in them what we already have inside us.", a = "Carlos Ruiz Zafón", b = "The Shadow of the Wind" },
    { q = "A book is a dream that you hold in your hands.", a = "Neil Gaiman" },
    { q = "Books are a uniquely portable magic.", a = "Stephen King", b = "On Writing" },
    { q = "A book is proof that humans are capable of working magic.", a = "Carl Sagan" },
    { q = "I cannot live without books.", a = "Thomas Jefferson" },
    { q = "Reading gives us someplace to go when we have to stay where we are.", a = "Mason Cooley" },
    { q = "A classic is a book that has never finished saying what it has to say.", a = "Italo Calvino", b = "Why Read the Classics?" },
    { q = "No two persons ever read the same book.", a = "Edmund Wilson" },
    { q = "If you only read the books that everyone else is reading, you can only think what everyone else is thinking.", a = "Haruki Murakami", b = "Norwegian Wood" },
    { q = "Until I feared I would lose it, I never loved to read. One does not love breathing.", a = "Harper Lee", b = "To Kill a Mockingbird" },
    { q = "I declare after all there is no enjoyment like reading!", a = "Jane Austen", b = "Pride and Prejudice" },
    { q = "Think before you speak. Read before you think.", a = "Fran Lebowitz", b = "Social Studies" },
    { q = "You don't have to burn books to destroy a culture. Just get people to stop reading them.", a = "Ray Bradbury" },
    { q = "The more that you read, the more things you will know. The more that you learn, the more places you'll go.", a = "Dr. Seuss", b = "I Can Read With My Eyes Shut!" },
    { q = "One must always be careful of books, and what is inside them, for words have the power to change us.", a = "Cassandra Clare", b = "City of Bones" },
    { q = "Sleep is good, he said, and books are better.", a = "George R.R. Martin", b = "A Clash of Kings" },
    { q = "You can never get a cup of tea large enough or a book long enough to suit me.", a = "C.S. Lewis" },

    -- Writing and storytelling
    { q = "There is no such thing as a moral or an immoral book. Books are well written, or badly written. That is all.", a = "Oscar Wilde", b = "The Picture of Dorian Gray" },
    { q = "A writer only begins a book. A reader finishes it.", a = "Samuel Johnson" },
    { q = "Writing is the painting of the voice.", a = "Voltaire" },
    { q = "If there's a book that you want to read, but it hasn't been written yet, then you must write it.", a = "Toni Morrison" },
    { q = "There is no greater agony than bearing an untold story inside you.", a = "Maya Angelou", b = "I Know Why the Caged Bird Sings" },
    { q = "Words are, in my not-so-humble opinion, our most inexhaustible source of magic.", a = "J.K. Rowling", b = "Harry Potter and the Deathly Hallows" },
    { q = "Fantasy is hardly an escape from reality. It's a way of understanding it.", a = "Lloyd Alexander" },
    { q = "A woman must have money and a room of her own if she is to write fiction.", a = "Virginia Woolf", b = "A Room of One's Own" },

    -- Opening and closing lines
    { q = "Call me Ishmael.", a = "Herman Melville", b = "Moby-Dick" },
    { q = "It was the best of times, it was the worst of times.", a = "Charles Dickens", b = "A Tale of Two Cities" },
    { q = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.", a = "Jane Austen", b = "Pride and Prejudice" },
    { q = "All happy families are alike; each unhappy family is unhappy in its own way.", a = "Leo Tolstoy", b = "Anna Karenina" },
    { q = "It was a bright cold day in April, and the clocks were striking thirteen.", a = "George Orwell", b = "Nineteen Eighty-Four" },
    { q = "So we beat on, boats against the current, borne back ceaselessly into the past.", a = "F. Scott Fitzgerald", b = "The Great Gatsby" },

    -- Adventure and imagination
    { q = "Not all those who wander are lost.", a = "J.R.R. Tolkien", b = "The Fellowship of the Ring" },
    { q = "All we have to decide is what to do with the time that is given us.", a = "J.R.R. Tolkien", b = "The Fellowship of the Ring" },
    { q = "It is good to have an end to journey toward; but it is the journey that matters, in the end.", a = "Ursula K. Le Guin", b = "The Left Hand of Darkness" },
    { q = "It is only with the heart that one can see rightly; what is essential is invisible to the eye.", a = "Antoine de Saint-Exupéry", b = "The Little Prince" },
    { q = "There's always another secret.", a = "Brandon Sanderson", b = "Mistborn: The Final Empire" },
    { q = "It does not do to dwell on dreams and forget to live.", a = "J.K. Rowling", b = "Harry Potter and the Philosopher's Stone" },
    { q = "It's the possibility of having a dream come true that makes life interesting.", a = "Paulo Coelho", b = "The Alchemist" },

    -- Love and friendship
    { q = "The best love is the kind that awakens the soul and makes us reach for more.", a = "Nicholas Sparks", b = "The Notebook" },
    { q = "Love does not consist in gazing at each other, but in looking outward together in the same direction.", a = "Antoine de Saint-Exupéry", b = "Wind, Sand and Stars" },
    { q = "To love at all is to be vulnerable.", a = "C.S. Lewis", b = "The Four Loves" },
    { q = "There is only one happiness in this life, to love and be loved.", a = "George Sand" },
    { q = "Whatever our souls are made of, his and mine are the same.", a = "Emily Brontë", b = "Wuthering Heights" },
    { q = "There is no charm equal to tenderness of heart.", a = "Jane Austen", b = "Emma" },
    { q = "We accept the love we think we deserve.", a = "Stephen Chbosky", b = "The Perks of Being a Wallflower" },

    -- Courage and perseverance
    { q = "I am no bird; and no net ensnares me: I am a free human being with an independent will.", a = "Charlotte Brontë", b = "Jane Eyre" },
    { q = "I am not afraid of storms, for I am learning how to sail my ship.", a = "Louisa May Alcott", b = "Little Women" },
    { q = "I took a deep breath and listened to the old brag of my heart: I am, I am, I am.", a = "Sylvia Plath", b = "The Bell Jar" },
    { q = "The world breaks everyone and afterward many are strong at the broken places.", a = "Ernest Hemingway", b = "A Farewell to Arms" },
    { q = "In the depths of winter, I finally learned that within me there lay an invincible summer.", a = "Albert Camus", b = "Return to Tipasa" },
    { q = "The impediment to action advances action. What stands in the way becomes the way.", a = "Marcus Aurelius", b = "Meditations" },
    { q = "Get busy living or get busy dying.", a = "Stephen King", b = "Different Seasons" },
    { q = "I must not fear. Fear is the mind-killer.", a = "Frank Herbert", b = "Dune" },
    { q = "Pain is inevitable. Suffering is optional.", a = "Haruki Murakami", b = "What I Talk About When I Talk About Running" },
    { q = "Darkness cannot drive out darkness; only light can do that. Hate cannot drive out hate; only love can do that.", a = "Martin Luther King Jr.", b = "Strength to Love" },

    -- Wisdom and understanding
    { q = "There is nothing either good or bad, but thinking makes it so.", a = "William Shakespeare", b = "Hamlet" },
    { q = "You never really understand a person until you consider things from his point of view... until you climb into his skin and walk around in it.", a = "Harper Lee", b = "To Kill a Mockingbird" },
    { q = "Freedom is the freedom to say that two plus two make four. If that is granted, all else follows.", a = "George Orwell", b = "Nineteen Eighty-Four" },
    { q = "It is our choices, Harry, that show what we truly are, far more than our abilities.", a = "J.K. Rowling", b = "Harry Potter and the Chamber of Secrets" },
    { q = "The only way out of the labyrinth of suffering is to forgive.", a = "John Green", b = "Looking for Alaska" },
    { q = "Some infinities are bigger than other infinities.", a = "John Green", b = "The Fault in Our Stars" },
    { q = "Live the questions now.", a = "Rainer Maria Rilke", b = "Letters to a Young Poet" },
    { q = "We suffer more often in imagination than in reality.", a = "Seneca", b = "Letters to Lucilius" },
    { q = "To live is the rarest thing in the world. Most people exist, that is all.", a = "Oscar Wilde", b = "The Soul of Man under Socialism" },
    { q = "In three words I can sum up everything I've learned about life: it goes on.", a = "Robert Frost" },
    { q = "How we spend our days is, of course, how we spend our lives.", a = "Annie Dillard", b = "The Writing Life" },
    { q = "The journey of a thousand miles begins with a single step.", a = "Lao Tzu", b = "Tao Te Ching" },

    -- Wit
    { q = "Outside of a dog, a book is a man's best friend. Inside of a dog it's too dark to read.", a = "Groucho Marx" },
    { q = "Classic — a book which people praise and don't read.", a = "Mark Twain" },
    { q = "I would be most content if my children grew up to be the kind of people who think decorating consists mostly of building enough bookshelves.", a = "Anna Quindlen" },
    { q = "Time is an illusion. Lunchtime doubly so.", a = "Douglas Adams", b = "The Hitchhiker's Guide to the Galaxy" },

}
