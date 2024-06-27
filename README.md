# AWS-LoadBalancerEC2-EFS
## [TF AWS Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

### Contenido de la actividad:
### Instrucciones Evaluación Parcial EA3 Almacenamiento en la nube 35%:
1. Cada alumno, deberá enviar código que Terraform, que permita desplegar la siguiente infraestructura el AWS.
2. Cree una VPC, utilizando el módulo de AWS (terraform-aws-modules/vpc/aws) considerando el siguiente detalle:
```
module "vpc" {
    source = "terraform-aws-modules/vpc/aws"
    
    name = "my-vpc"
    cidr = "10.0.0.0/16"
    
    azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
    public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
    
    enable_nat_gateway = true
    enable_vpn_gateway = false
    
    tags = {
        Terraform = "true"
        Environment = "prd"
    }
}
```

3. Cree un "Security Group" que permita conexiones al puerto tcp/80 (http), tcp/443 (https) y tcp/22 (ssh).
4. Cree un bucket S3, copie el siguiente archivo “.php”:

```php
<html xmlns="http://www.w3.org/1999/xhtml" >
    <head>
        <title>My Website Home Page</title>
    </head>
    <body>
        <h1>Welcome to my website</h1>
        <p>Now hosted on: <?php echo gethostname(); ?></p>
        <p><?php $my_current_ip=exec("ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'");
        echo $my_current_ip; ?></p>
    </body>
</html>
```
5. Lanze 3 Instancias Virtuales en EC2, cada una en una AZ distinta (availability zone) y en las subredes públicas disponibles. Para cada una de estas instancias, asocie la llave de usuario (Key user) "vockey" y el "Security Group" configurado en el punto 1.
6. Lance un volumen EFS y montelo dentro de cada una de las instancia EC2 en el path /var/www/html.

7. Instale el servicio webserver (apache) y php en cada instancia EC2 (Puedes usar “EC2 user data” para realizar esto.
    ```sudo yum install -y httpd php```

8. Copie desde el bucket S3, el archivo “index.php” hacie el path /var/www/html (EFS). 
9. Cree un Balanceador de Carga (ALB) en AWS adjuntando las 3 máquinas creadas antes como targets. Este LB también debe aceptar conexiones en el puerto 80 desde cualquier dirección IP. 

# Terraform comandos básicos
- terraform init
- terraform init --upgrade
- terraform apply -auto-approve
- terraform destroy

# Generar grafico de la IaaC
- terraform graph > graph.dot
- sudo dnf install graphviz
- dot -Tpng graph.dot -o graph.png

# Tf.main index

# Orden de elementos en GUI
### Crear los Grupos de Seguridad:
    1. Grupo de Seguridad para las Instancias EC2:
        - Permitir tráfico entrante en el puerto 80 (HTTP) desde el grupo de seguridad del ALB.
        - Permitir tráfico NFS (puerto 2049) desde el grupo de seguridad del EFS.
    2. Grupo de Seguridad para el EFS:
        - Permitir tráfico NFS (puerto 2049) desde el grupo de seguridad de las instancias EC2.
    3. Grupo de Seguridad para el ALB:
        - Permitir tráfico HTTP entrante en el puerto 80 desde Internet.

### Crear la VPC y Subnets:
    1. VPC:
        - Navega a la sección de VPC en la consola de AWS.
        - Crea una nueva VPC con un bloque CIDR (por ejemplo, 10.0.0.0/16).
        - Subnets dentro de la VPC, crea tres subnets privadas (una en cada zona de disponibilidad: us-east-1a, us-east-1b, us-east-1c), por ejemplo:
                1.  us-east-1a: 10.0.1.0/24
                2.  us-east-1b: 10.0.2.0/24
                3.  us-east-1c: 10.0.3.0/24

    2. Crear el Internet Gateway y NAT Gateway:
        - Internet Gateway:
            - Crea un Internet Gateway y asígnalo a la VPC.
        - Subnet Pública para el NAT Gateway:
            - Crea una subnet pública adicional en una de las zonas de disponibilidad.
        - NAT Gateway:
            - Crea un NAT Gateway en la subnet pública y asígnale una Elastic IP.
        - Tabla de Rutas:
            - Crea una nueva tabla de rutas y asócialo a las subnets privadas.
            - Añade una ruta en la tabla de rutas que permita el tráfico a Internet (0.0.0.0/0) a través del NAT Gateway.

### Crear el Bucket S3:
    - Navega a la sección de S3 en la consola.
    - Crea un nuevo bucket y sube el archivo PHP que necesitarás.

### Crear el EFS:
    - Navega a la sección de EFS en la consola.
    - Crea un nuevo sistema de archivos EFS y configúralo para estar disponible en las tres zonas de disponibilidad.
    - Asigna el grupo de seguridad correspondiente para permitir el acceso NFS desde las instancias EC2.

### Crear las Instancias EC2:
    - Navega a la sección de EC2 en la consola.
    - Lanza tres instancias EC2, cada una en una de las subnets privadas.
    - Asigna el grupo de seguridad de EC2 a estas instancias.
    - Configura un script de userdata para cada instancia que:
        1. Instale Apache.
        2. Monte el EFS.
        3. Descargue el archivo PHP desde el bucket S3.
    - Asegúrate de que las instancias tengan un rol de IAM que permita acceso al bucket S3.

### Crear el Application Load Balancer (ALB):
    - Navega a la sección de EC2 y selecciona "Load Balancers".
    - Crea un nuevo Application Load Balancer.
        1. Configúralo para estar en las tres zonas de disponibilidad.
        2. Crea un listener en el puerto 80.
        3. Asigna el grupo de seguridad del ALB.
    - Crea un target group y registra las instancias EC2 en el target group.
    - Configura el listener para redirigir el tráfico al target group.

### Probar la Configuración:
    - Una vez que todo esté configurado, navega a la dirección del ALB para asegurarte de que el tráfico se redirige correctamente a las instancias EC2 y que el archivo PHP se está sirviendo correctamente.

## Resumen del Orden Actualizado:
    1.Crear los Grupos de Seguridad.
    2.Crear la VPC y Subnets.
    3.Crear el Internet Gateway y NAT Gateway.
    4.Crear el Bucket S3.
    5.Crear el EFS.
    6.Crear las Instancias EC2.
    7.Crear el Application Load Balancer (ALB).
    8.Probar la Configuración.

# Dudas de clase GUI
vpc primero
sg -> ec2, alb, efs
sg rules
ec2 instances -> ec2-sg -> vpc-private-a-subnet -> script
target group
configurar alb