#!/usr/bin/env perl

use 5.16.0;
use warnings;
use diagnostics;
no if $] >= 5.018, warnings => "experimental";
use Data::Dumper;

=pod

=head1 NAME

SPAM REPORTER

=head1 DESCRIPTION

Script que analisa emails com base em arquivos de configuracao (config.txt) e reporta em caso de spam.
O Programa foi escrito em perl devido tanto os requisitos como devido a eficiencia da linguagem em tratar textos e expressoes regulares.

=head1 AUTHOR

Manoel Domingues Junior (mdjunior@ufrj.br)

=head1 SYNOPSIS

./spam_reporter.pl spam.eml

=head2 Configuracoes 

O script inicia com uma serie de parametros que retratam:

- Nivel minimo para ser um SPAM

- Local padrao do arquivo de configuracao

- Modo debug (se ativado ou nao)

=cut

my $padrao = 100;
my $config = 'config.txt';
my $config_padrao = 'config.txt';
my $google_apikey = '';
my $debug_mode = 0;

# Parametros do email
my $nota_email = 0;
my $nota_final = 0;

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=head2 Funcoes

=over

=item verifica_arquivo_config

A funcao valida os arquivos de configuracao, de modo que o script seja capaz de acessa-los e parsea-los.

Essa e uma funcao so de verificacao, onde nada e escrito na tela, e ela retorna 0 (ok) ou o codigo de erro conforme abaixo.

Codigos de retorno:

1 - arquivo nao existe

2 - arquivo existe mas esta vazio

3 - arquivo existe mas sem permissao de leitura

4 - falha ao abrir o arquivo

5 - arquivo sem nenhuma categoria

6 - arquivo sem item
 
=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub verifica_arquivo_config 
{
	my $configfile = $_[0];
	if (! -e $configfile ) { return 1; }
	if ( -z $configfile ) { return 2; }
	if (! -r $configfile ) { return 3; }
	open my $fileh, '<', $configfile or return 4;

	my $categorias = 0;
	my $itens = 0;
	while (<$fileh>)
	{
		if ( /^categoria\s+\w+/ ) { $categorias++; }
		if ( /^\w+\s+[0-9]+/ ) { $itens++; }
	}
	close ($fileh);
	if (! $categorias ) { return 5; }
	if (! $itens ) { return 6; }
	return 0;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item carrega_config

Essa funcao carrega a configuracao e retorna ela em um hash. 

Ela e responsavel por parsear o arquivo de configuracao e de montar a estrutura hierarquica no hash.

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub carrega_config
{
	my $configfile = $_[0];
	my $hash;
	open my $fileh, '<', $configfile or return 1;

	# variavel que controla a ultima categoria encontrada
	my $last_cat;
	while (<$fileh>)
	{
		if ( /^categoria\s+(?<categoria>\w+)/ )
		{
			#$hash->{$+{categoria}};
			$last_cat = $+{categoria};
		}
		if ( /(?<item>^\w+)\s+(?<valor>[0-9]+)/ )
		{
			${$hash->{$last_cat}}->{$+{item}} = $+{valor};
		}
	}
	close ($fileh);
	if ($debug_mode) { print Dumper $hash;}

	return $hash;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item parseia_email

A funcao parseia_email e a que responsavel por ler o conteudo do email e separar o corpo dos atributos do cabecalho.

E uma das funcoes mais importantes onde grande parte do trabalho comeca a ser realizado com o uso de expressoes regulares nomeadas.

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub parseia_email
{
	my $email = $_[0];
	open my $fileh, '<', $email or return 1;

	my $hash;	
	my $last_line;
	while (<$fileh>)
	{
		if (/^$/)
		{
			# verificando se ja foi iniciado o parser do header
			# se ja foi iniciado e teve um '\n' acabou o header e agora vem o body
			if ($. == 1) { next;}else { $last_line->{body} .= "\n"; }

		};
		if (defined($last_line->{body})) { $last_line->{body} .= $_; next;}

		# Verifica se eh parte do header
		if (/^(?<header>[^:\s]+):\s*(?<value>.*)/)
		{
			# se existir um header anterior, grava ele no hash
			if (defined($last_line->{nome}) && defined($last_line->{valor}))
			{
				if ($debug_mode) { say "INSERINDO: $last_line->{nome} -> $last_line->{valor}";}
				push @{$hash->{$last_line->{nome}}}, $last_line->{valor};
				$last_line->{nome} = undef; $last_line->{valor} = undef;	
			}
			if ($debug_mode) { say "HEADER: $+{header} -> $+{value}";}
			$last_line->{nome} = $+{header};
			$last_line->{valor} = $+{value};
		}else
		{
			if ($debug_mode) { say "CONTINUACAO!";}
			/\s*(?<cont>.*)/;
			$last_line->{valor} .= " $+{cont}";
			next;
		}

	}
	# gravando o body
	push @{$hash->{body}}, $last_line->{body};
	if ($debug_mode) { print Dumper $hash;}
	close ($fileh);

	return $hash;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=back

=head2 Deteccao de SPAM: CATEGORIAS

As funcoes nessa secao sao responsaveis por detectar e atribuir os pesos e caracteristicas definidas no arquivo de configuracao.

=over

=item palavras

Faz a checagem da categoria palavras.
Essa categoria busca no corpo do email as palavras configuradas como itens e atribui a nota correspondente a cada uma que foi encontrada. 
Cada item e contado somente uma vez.

uso B<palavras($hash_do_email,item,pontuacao)> - retorna a pontuacao aferida

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub palavras
{
	my $nota = 0;
	my $email = $_[0];
	my $item = $_[1];
	my $valor = $_[2];
	for (@{$email->{"body"}})
	{
		if ($debug_mode) { say "palavras: testando por $item";}
		if (/$item/)
		{
			$nota += $valor;
			if ($debug_mode) { say "-> palavras: item $item encontrado";}
		}
	}
	return $nota;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item ip

Faz a checagem da categoria IP. 
Nessa categoria sao checados os resultados de verificacao do SPF presente nos headers do email alem de verificar se os enderecos de IP por onde o email passou possuem registros MX no dominio de email do remetente. 

Nas checagens de SPF a pontuacao e feita de forma gradatica. Veja a seguir:

pass		0%

neutral	50%

none		60%

softfail	70%

fail		100%

uso B<ip($hash_do_email,item,pontuacao)> - retorna a pontuacao aferida

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub ip 
{
	my $nota = 0;
	my $email = $_[0];
	given ($_[1])
	{
		when (/spf/)
		{
			for (@{$email->{"Received-SPF"}})
			{
				if ($debug_mode) { say "ip:spf: verificando registro $_";}
				if (/^\s*pass.*/) { $nota += 0;} 		if ($debug_mode) {say "-> ip:spf: adicionando $nota (pass)";}
				if (/^\s*neutral.*/) { $nota += 0.5*$_[2];} 	if ($debug_mode) {say "-> ip:spf: adicionando $nota (neutral)";}
				if (/^\s*none.*/) { $nota += 0.6*$_[2];} 	if ($debug_mode) {say "-> ip:spf: adicionando $nota (none)";}
				if (/^\s*softfail.*/) { $nota += 0.7*$_[2];} 	if ($debug_mode) {say "-> ip:spf: adicionando $nota (softfail)";}
				if (/^\s*fail.*/) { $nota += 1*$_[2];} 		if ($debug_mode) {say "-> ip:spf: adicionando $nota (fail)";}
			}
		}
		when (/mx/)
		{
			my @ips;
			my @domain;
			my $valor = $_[2];
			for (@{$email->{"Received"}})
			{
				if ( /(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/ )
				{
					if ($debug_mode) { say "ip:mx: adicionando IP do Received $+{ip}";}
					push @ips, $+{ip};
				}
			}
			for (@{$email->{"From"}})
			{
				if (/@(?<domain>[\w.]+)/) 
				{
					my $dig_1 = `dig -t MX $+{domain}`;
					my @dig_1 = split "\n", $dig_1;
					for (@dig_1)
					{
						if (/[\w+\.]+\s+\d+\s+IN\s+MX\s+\d+\s+(?<result>[\w+\.]+)/)
						{ 
							my $dig_2 = `host $+{result}`;
							if ($dig_2 =~ /(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
							{ 
									if ($debug_mode) { say "ip:mx: adicionando IP do From $+{ip}";}
									push @domain,$+{ip};
							}
						}
					}
				}
			}
			# Verificando a intersecao dos array usando hashes
			my @union = my @isect = my @diff = ();
			my %union = my %isect = ();
			my %count = ();
			foreach my $e (@ips, @domain) { $union{$e}++ && $isect{$e}++ }
			@isect = keys %isect;
			if ($#isect >= 0 ) 
			{
				say "$#isect";
				if ($debug_mode) { say "-> ip:mx: IPs nao batem - adicionando $valor";}
				return $valor;
			}	
		}
		default {return 0;}
	}
	return $nota;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item reputacao

Faz a verificacao da reputacao dos dominos no do email utilizando o Google Safe Browsing.
No caso, tanto em casos de malware como phishing o email recebera a mesma pontuacao.

B<OBS: A API e somente para exemplo, a chave e pessoal e intransferivel, logo, nao utilize fora desse script!>

uso B<reputacao($hash_do_email,fonte_de_consulta,pontuacao)> - retorna a pontuacao aferida
=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub reputacao
{
	my $nota = 0;
	my $email = $_[0];
	given ($_[1])
	{
		when (/google/)
		{
			for ( @{$email->{"body"}} )
			{
				if (/(?<domain>http\:\/\/[a-zA-Z0-9\-\.?]+)/i)
				{
					if ($debug_mode) { say "reputacao:google: verificando dominio $+{domain}";}
					my $result = `curl -sk 'https://sb-ssl.google.com/safebrowsing/api/lookup?client=demo-app&apikey=$google_apikey&appver=1.5.2&pver=3.0&url=$+{domain}'`;
					if (! ($result =~ /ok/))
					{
						if ($debug_mode) { say "-> reputacao:google: $result - $_[2]";}
						$nota += $_[2];
					}
				}
			}
			return $nota;
		}
	}
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item reply

Faz a checagem da categoria reply, conferindo se os emails presentes nos arrays do Reply-To e Body coincidem com os do From.
Geralmente spammers usam enderecos diferentes para enviar e para receber de modo a dificultar a detecao. 

uso B<reply($hash_do_email,item,pontuacao)> - retorna a pontuacao aferida
=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub reply 
{
	my $nota = 0;
	my $email = $_[0];
	given ($_[1])
	{
		when (/replyto/)
		{
			my @emails;
			my @emails_reply_to;
			for (@{$email->{"From"}})
			{
				if (/(?<email>[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})/i)
				{
					if ($debug_mode) { say "reply:replyto: adicionando email do From $+{email}";}
					push @emails,$+{email};
				}
			}
			if (! defined(${$email->{"Reply-To"}}[0]))
			{
				if ($debug_mode) { say "reply:replyto: email sem Reply-To";}
				return 0;
			}
			for (@{$email->{"Reply-To"}})
			{
				if (/(?<email>[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})/i)
				{
					if ($debug_mode) { say "reply:replyto: adicionando email do Reply-To $+{email}";}
					push @emails_reply_to,$+{email};
				}
			}
			# Verificando a intersecao dos array usando hashes
			my @union = my @isect = my @diff = ();
			my %union = my %isect = ();
			my %count = ();
			foreach my $e (@emails, @emails_reply_to) { $union{$e}++ && $isect{$e}++ }
			@isect = keys %isect;
			if ($#isect < 0)
			{
				if ($debug_mode) { say "reply:replyto: nao existem emails em comum"; say "-> reply:replyto: adicionando $_[2]";}
				return $_[2];
			};	
		}
		when (/body/)
		{
			my @emails;
			my @emails_body;
			for (@{$email->{"From"}})
			{
				if (/(?<email>[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})/i)
				{
					if ($debug_mode) { say "reply:body: adicionando email do From $+{email}";}
					push @emails,$+{email};
				}
			}
			for ( @{$email->{"body"}} )
			{
				if (/(?<email>[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4})/i)
				{
					if ($debug_mode) { say "reply:body: adicionando email do Body $+{email}";}
					push @emails_body,$+{email};
				}
			}
			# Verificando a intersecao dos array usando hashes
			my @union = my @isect = my @diff = ();
			my %union = my %isect = ();
			my %count = ();
			foreach my $e (@emails, @emails_body) { $union{$e}++ && $isect{$e}++ }
			@isect = keys %isect;
			if ($#isect < 0)
			{
				if ($debug_mode) { say "reply:body: nao existem emails em comum"; say "-> reply:body: adicionando $_[2]";}
				return $_[2];
			}	
		}
	}
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item blacklist

Faz a checagem da categoria blacklist. 
Essa funcao utiliza dados provenientes do Team Cymru para obter informacao regional.

uso B<blacklist($hash_do_email,item,pontuacao)> - retorna a pontucao aferida

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub blacklist
{
	my $nota = 0;
	my $email = $_[0];
	given ($_[1])
	{
		my $cc = $_[1];
		my $valor = $_[2];
		default	
		{
			my @ips;
			for (@{$email->{"Received"}})
			{
				if ( /(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/ )
				{
					if ($debug_mode) { say "blacklist:received: adicionando IP $+{ip}";}
					push @ips, $+{ip};
				}
			}
			for (@ips)
			{
				my $result = `whois -h whois.cymru.com " -c -q -o -s -b -u -f -x $_"`;
				if ($result =~ /\d+\s*\|[^|]*\|\s*(?<cc>\w+)/)
				{
					my $cc_match = $+{cc};
					if ($cc =~ /$cc_match/i)
					{
						if ($debug_mode) { say "-> blacklist:received: $cc - $_ - adicionando $valor";}
						$nota += $valor;
					}
				}
			}
		}
	}
	return $nota;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=item whitelist

Faz a checagem da categoria whitelist. 
A funcao chama a funcao blacklist e inverte o sinal do valor retornado de modo a diminuir a nota do email. 
Assim, caso ele esteja na whitelist a chance dele entrar como spam, dominui.

uso B<whitelist($hash_do_email,item,pontuacao)> - retorna a pontuacao aferida

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
sub whitelist
{
	my $neg = -1;
	if ($debug_mode) { say "whitelist:$_[1]: Iniciando...";}
	my $nota = blacklist($_[0],$_[1],$_[2]);
	return $neg * $nota;
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=back

=head2 MAIN

Aqui comeca a execucao principal do programa. 
Iniciamos definindo a variavel que armazeno o retorno da verificacao do arquivo de configuracao em 1.
Assim, caso o arquivo nao seja validado, o programa entrara em loop ate um arquivo valido ser inserido.

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
# Colocando a verificacao do arquivo em falso para iniciar o loop
my $verificacao_arquivo = 1;

while ($verificacao_arquivo)
{
	# Reiniciando(depois da primeira execussao) com arquivo padrao
	my $config = $config_padrao;

	# Verificando configuracao
	say "Deseja usar o arquivo de configuracao padrao ($config)? (S/N)";
	my $teclado = <STDIN>;
	chop ($teclado);

	if ($teclado =~ /^\s*[Nn]/ )
	{
		say "Digite o nome do arquivo de configuracao:";
		chomp ($config = <STDIN>);
		say "Verificando arquivo: $config";
		$verificacao_arquivo = verifica_arquivo_config($config);
		if ($verificacao_arquivo == 0)
		{
			say "Arquivo verificado: $config";
		}else{ 
			say "Arquivo $config com problemas! Reiniciando...";
		}

	} else
	{
		say "Verificando arquivo: $config";
		$verificacao_arquivo = verifica_arquivo_config($config);
		if ($verificacao_arquivo == 0)
		{
			say "Arquivo verificado: $config";
		}else{
			say "Arquivo $config com problemas! Reiniciando...";
		}
	}
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

Apos inserir um arquivo valido, ele e verificando novamente o para a execucao principal do programa.

Apos validar o arquivo, o mesmo e carregado e o email e parseado. A partir desse ponto, a execucao das categorias comeca.
As categorias sao colocadas manualmente de forma a ter um maior controle e evitar problemas devido o arquivo de configuracao (ele pode estar com categorias que nao existem).

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
if (verifica_arquivo_config($config))
{
	# Problemas com o arquivo de configuracao, saindo...
	return 1;
}else{

	my $nota = 0;

	# Carregando a configuracao em um hash
	my $hash_config = carrega_config($config);

	# Carregando o email em um hash
	my $hash_email = parseia_email($ARGV[0]);

	foreach my $categoria (keys %{ $hash_config }) 
	{
		#say "  Checando categoria: $categoria";

			#foreach my $item (keys ${ %{$hash_config}->{$categoria}})
			foreach my $item (keys ${ $hash_config->{$categoria} })
			{
				if ($debug_mode) { say "EXECUSAO FINAL: $categoria : $item -> ${ $hash_config->{$categoria} }->{$item}";}
				if ($categoria eq 'palavras' )	{ $nota += palavras($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
				if ($categoria eq 'reputacao' )	{ $nota += reputacao($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
				if ($categoria eq 'ip' )	{ $nota += ip($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
				if ($categoria eq 'reply' )	{ $nota += reply($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
				if ($categoria eq 'blacklist' )	{ $nota += blacklist($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
				if ($categoria eq 'whitelist' )	{ $nota += blacklist($hash_email,$item,${ $hash_config->{$categoria} }->{$item});}
			}
	}
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

Aqui o programa termina e exibe os dados para o usuario.

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
	$nota_final = $nota;
	say "-> A nota final foi: $nota";
	if ($nota  > $padrao) { say "-> Eh SPAM";}else{ say "-> Nao eh SPAM";}
}

# - - - - - - - - - - - - - - - - - - - - - - - - - - 
=pod

=head1 CAVEATS

Algumas dicas. Para acompanhar execucao, mude o mode_debug para = 1;

=cut
# - - - - - - - - - - - - - - - - - - - - - - - - - - 
